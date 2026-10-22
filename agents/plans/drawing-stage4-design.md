# Drawing stage 4 design: bytes on the wire

**Status:** design, for the primary agent's review; nothing is built. Stage 4 of `agents/plans/drawing-only-what-changed.md`, under ADR 17 ("Assembly": pieces kept as UTF-8 bytes, written into the stream in order), after stages 2 and 3 as built. Line numbers: Tuna at `f58772a`, gerbil-sse at `1a8609e`, gerbil-datastar at `a0d020c`.

**Today.** Every screen is copied four times as a whole: `html-string` joins children into each parent's string (`renderer/plugin.ss:182-209`); `stamp-revision` and `stamp-applied` copy it through `add-root-attributes` (`web/plugin.ss:169-190`); `patch-elements` scans it for CR and NUL, splits it into lines and builds the frame through a string port (`core.ss:39-55, 360-379, 381-423`); `sse-send!` encodes that to UTF-8 (`sse.ss:50`). Measured at 35 KB: about 320 µs and 367 KB per screen, against about 5 µs for writing cached UTF-8 bytes to the writer (`agents/research/rendering/gerbil-mechanics.md`).

## 1. gerbil-sse: write one frame

```scheme
;; Call (WRITE W) with the session's BufferedWriter W while holding its lock,
;; then flush: what WRITE writes reaches the client as one frame, never
;; interleaved with another send. Returns void.
(def (call-with-sse-frame session write) ...)
(def (sse-send! session frame)                     ; unchanged API and messages
  (unless (sse? session) (fail "invalid session" session))
  (unless (string? frame) (fail "frame must be a string" frame))
  (call-with-sse-frame session (lambda (w) (BufferedWriter-write-string-utf8 w frame))))
```

- **Name.** "Frame" is the package's word for what `sse-send!` writes ("one preframed SSE string", README); the primitive frames nothing either, so a caller may write one event or several. (The plan called it "write one event".)
- **Checks**, before the lock, in the package's style (explicit checks with `fail` messages, which the tests assert): `"sse: invalid session"`, then `"sse: frame writer must be a procedure"`.
- **Lock, state and errors: `sse-send!`'s body (`sse.ss:45-58`) moves into it unchanged.** In state `open`, run `(write w)` then `BufferedWriter-flush`. Any exception from either latches the first failure, sets `failed`, and re-raises. `failed` re-raises the latched failure; `closed` fails `"sse: session is closed"`. So an exception raised by WRITE itself also fails the session: part of a frame may already be in the buffer or on the wire, and nothing may follow it.
- **Nested sends.** Gambit mutexes are not recursive, so a send on the same session from inside WRITE would deadlock. Before locking, `(eq? (mutex-state (sse-mutex session)) (current-thread))` fails `"sse: send while writing a frame"`.
- **W is valid only during WRITE.** It is the response's writer; the README says so.
- **Tests** (`sse-test.ss`, beside the existing ones, which stay unchanged):
  - a frame written in several pieces arrives as one flushed sink write;
  - an exception from WRITE latches: later `sse-send!` and `call-with-sse-frame` re-raise it, and the normal close is skipped (mirrors `:191-209`);
  - argument errors, and closed-session errors, come before any write;
  - a nested send fails and does not hang;
  - two threads, one writing "a", `thread-yield!`, "b" through `call-with-sse-frame` and one using `sse-send!`, never interleave;
  - the wire and gzip cases (`:305-363`) also run through `call-with-sse-frame`.
- **README:** a fourth export and a three-line example writing two byte vectors as one frame.

## 2. gerbil-datastar: `call-with-patch-elements`

```scheme
;; One datastar-patch-elements event whose elements PROC writes: the event's
;; header and option lines, then (PROC W) with W a BufferedWriter for the
;; elements as UTF-8, where each newline starts a new "data: elements" line,
;; then the end of the event. Options as patch-elements.
(def (call-with-patch-elements session proc
                               selector: mode: namespace: use-view-transitions?:
                               view-transition-selector: event-id: retry-duration:) ...)
```

`http/api.ss` and `http.ss` export it, next to `patch-elements`. `core.ss` holds `call-with-patch-elements/core`, as for the other three operations.

**One send path.** `event-frame` and `send-frame!` (`core.ss:360-379`) are replaced by one internal procedure, the SDK specification's unified `send` (`sdk/ADR.md` "ServerSentEventGenerator.send", "should be used internally"):

```scheme
;; EVENT, then id and retry unless defaults, then each DATA line (KEY . VALUE),
;; then, when STREAMED is (KEY . PROC), the data lines PROC writes as KEY lines,
;; then the blank line: one frame through call-with-sse-frame.
(def (send-event! session (event : :string) (data : :list) event-id retry (streamed : :t)) => :void)
```

- It checks the event name and `event-id`/`retry` (`check-single-line`, `check-event-id-retry`), then `(sse? session)` (`"datastar: invalid SSE session"`), in today's order. Then, inside `call-with-sse-frame`, it writes each part with `BufferedWriter-write-string-utf8`; numbers go through `number->string`, as `display` writes them. No frame string is built.
- `patch-elements/core` with a string, `patch-signals/core` and `execute-script/core` keep all their checks before any write (`:389-409, 425-438, 494-513`). They pass their lines as `data`, split as today (`split-lines`). So their "no event output" errors, all of `core-test.ss:305-432`, are unchanged.
- `call-with-patch-elements/core` runs the same option checks, through a helper shared with `patch-elements/core` (`:389-409` minus the elements checks). It also rejects `mode: 'remove` (`"datastar: remove mode has no elements"`) and a PROC that is not a procedure (`"datastar: elements writer must be a procedure"`), all before writing. Then it calls `send-event!` with `streamed` = `("elements" . PROC)`.

**The elements writer** (private, in `core.ss`): a struct `(sink : BufferedWriter) (open? : :boolean) (count : :fixnum)`. It implements `BufferedWriter`, as `sse-test.ss:26-35` implements `Writer`:

- **Start.** Before PROC runs, `send-event!` writes `data: elements ` to the sink.
- **`write u8v start end`.** Scans the bytes for 10, 13 and 0, and copies each run between them to the sink with one `BufferedWriter-write`. Bytes below 128 never occur inside a multi-byte UTF-8 sequence, so a byte scan is exact.
  - **10** writes `\ndata: elements ` (a constant byte vector) instead.
  - **13 or 0** fail `"datastar: elements contains CR or NUL"`, the message and rule of `check-content` (`:39-44`).
  - It returns `end - start` and adds to `count`.
  - The scan is the only pass over the bytes, so there is no second validation pass. It runs on `##u8vector-ref` and `##fx` operations under `(declare (not safe))`, in its own module (`http/private/elements.ss`, added to `build.ss`), so the declaration covers nothing else. Measured, compiled, over 100 leaves of 350 bytes: 26 µs per 35 KB; the same loop with checked typed operations took 220 µs; plain writes took 2.7 µs (`/tmp/scanbench`, to be redone in the prototype step).
- **`write-u8 b`.** The same rules for one byte. So the generic `BufferedWriter-write-string-utf8` works on W too, one byte at a time. A fast caller writes encoded bytes.
- **`flush`** does nothing: the event is flushed once, when it ends.
- **`close`** fails `"datastar: the elements writer closes with its event"`.
- **After PROC returns.** `open?` becomes `#f`, and any later call fails `"datastar: elements writer used after its event"`. Zero bytes written fail `"datastar: non-remove elements must not be empty"`, as `patch-elements` does for `""`. Otherwise it writes `\n`, and `send-event!` writes the blank line.
- **Errors after the header.** They happen inside `call-with-sse-frame`, so the session fails and nothing more is sent on it. The client sees a frame without its blank line. SSE dispatches an event only at its blank line, so that frame is never applied. This is the one behaviour difference from `patch-elements`, and it applies only to the streamed form. A string given to `patch-elements` is still checked before anything is written.

**Same bytes.** Starting with `data: elements `, writing `\ndata: elements ` for each 10 and ending with `\n` produces exactly `split-lines`' lines, empty ones included. For `"\nα\n"`, both give `data: elements \ndata: elements α\ndata: elements \n` (`core-test.ss:283`).

**Tests** (`core-test.ss`):
- **Old against new.** A frozen copy of today's `event-frame` in the test file is the reference. Every frame of a matrix (each mode and namespace, transitions with and without a selector, event id, retry 1000 and 2000, signals as a hash and as text, scripts with attributes) is compared with it, byte for byte, through all three string operations.
- **Streamed against string.** For each element string in a set (`"x"`, `"a\nb"`, `"\nα\n"`, `"\n"`, the SVG case at `:248`, 40 KB with newlines), `call-with-patch-elements` writing its UTF-8:
  - in one write;
  - one byte at a time through `write-u8`;
  - in two writes split at every offset, for the short strings;
  - through `BufferedWriter-write-string-utf8`;

  equals `patch-elements` with that string and the same options.
- **Errors without output:** option errors, `mode: 'remove`, and a PROC that is not a procedure (`check-session-error`).
- **Errors that fail the session:** CR or NUL in a write, `write-u8` of 13, zero bytes written, and PROC raising. Each fails the session, the next `patch-signals` re-raises the failure, and the stream's bytes end without a blank line.
- **Misuse:** writing after the event; `close` and `flush` on W.
- **Unchanged:** the existing trace checks (`begin force write force end`), since the buffered writer still delivers a small frame as one sink write.
- **Conformance:** `gerbil test -D datastar-conformance ./http/conformance-test.ss` (Go 1.26 is installed), unchanged, since the API it drives is unchanged.

**README:** a usage example for cached byte fragments:

```scheme
(call-with-patch-elements session
  (lambda (out)
    (BufferedWriter-write out open-tag)         ; u8vectors, written as they are
    (for-each (cut BufferedWriter-write out <>) cached-rows)
    (BufferedWriter-write out close-tag))
  selector: "#rows" mode: 'inner)
```

It adds that newlines in the elements become new `data: elements` lines, that CR or NUL fail the session, and that W is valid only inside PROC.

**Conformance with the SDK ADR.**
- Every event goes through one internal send, which writes event, id, retry (unless 1000), data lines and the blank line in that order, and flushes once.
- PatchElements calls it with `datastar-patch-elements` and writes one `elements` line per line of HTML, with option lines only for non-defaults.
- Errors are raised.
- `call-with-patch-elements` is an addition, as the Clojure SDK's `patch-elements-seq!` is. It follows the same data-line rules, so its bytes are those of `PatchElements` given the concatenated HTML. Hyperlith writes its cached byte fragments after one `data: elements ` prefix the same way (`impl/datastar.clj` `html->stream!`).

## 3. Tuna

**HTML as bytes** (renderer contract, which owns `render-screen`'s result):

```scheme
;; HTML drawn already, as UTF-8: a u8vector, or a vector of html, read in order.
;; Never mutated once made: pieces are shared by frames and tabs.
(interface Renderer (render-screen (c :? client)) => :t)    ; html; was :string
(def (html-for-each (write : :procedure) (h : :t)) => :void) ; each u8vector, in order
(def (html->string (h : :t)) => :string)                     ; for the page and tests
```

- Vectors, not lists, because SXML never contains a vector or a u8vector. So a child's HTML placed anywhere in a node renderer's SXML is told apart from markup, and is kept as one element: a parent refers to it and never copies or splices it. This replaces `*unencoded*`.
- `context-define-node-renderer!`'s comment (`buffers/contract.ss:775-776`) says the children are HTML to place as they are, not to inspect. No node renderer inspects them today.
- Two trees with the same bytes may be split differently. `equal?` then calls them different, which costs one redundant send, never a wrong screen.

**Renderer plugin.** Every piece's value is html:
- **`markup->html`** replaces `html-string`, `sxml-string`, `holds-fragment?` and `html-parts` (`:182-209`):
  - markup holding no u8vector or vector is written once by `write-sxml` to a UTF-8 u8vector port (`(open-output-u8vector (list char-encoding: 'UTF-8))`, checked equal to `string->utf8` of the string port's output);
  - an element holding one is written as a vector: its start tag's bytes, each child's html or markup, and its end tag's bytes. Today's shell-splitting code does this, producing bytes.
- `render-node`, the line pieces in `render-text-node` and `render-view` place `(memo ...)` values directly instead of `['*unencoded* ...]` (`:237, 475-480, 682`). `draw-node`, `draw-line`, `draw-view` and `draw-screen` return html.
- The screen piece is `#(<main id="screen" class="screen"> view... </main>)`.
- A line that changed redraws its own bytes. Each ancestor still runs its draw, because it read the changed source. That draw now writes only its own tags and allocates one vector of references: the copying half of TODO "A changed line's ancestors rebuild their strings" is closed, and the reruns remain.
- `after-drawing!`'s `eq?` test (`:724`) and the `memo` cache are unchanged; no table is added, so no weak table is needed (`gerbil-mechanics.md` pitfall).
- **`tuna/lib/memo.ss`.** `difference` (`:287`, diagnostics only) shows u8vectors and vectors of them as text, so a test-mode failure still says where two drawings differ. Equality stays `equal?`.

**Web plugin.** No whole-screen copy remains:
- **The tab keeps the renderer's html**, `rendered : :t` (the empty screen's bytes at first), with `revision`. Its `screen` field goes, and so do `stamp-revision`, `stamp-applied` and `add-root-attributes` (`:111-126, 169-190`).
- **Stamps.** At send, the writer thread makes one small u8vector:

  ```scheme
  (def (screen-stamps (revision : :fixnum) (stream :? :fixnum) (count :? :fixnum)) => :u8vector)
  ```

  It holds ` data-init="@post('/applied?stream=S&amp;count=N'); el.removeAttribute('data-init')"` and then ` data-revision="R"`, in today's order: `stamp-applied` inserted data-init before the data-revision `stamp-revision` had put after the tag name. The page uses it without data-init.
- **Writing the screen.**

  ```scheme
  ;; SCREEN's bytes to OUT, with STAMPS after its root element's tag name (the
  ;; first space, tab, newline, > or / after its first byte, as add-root-attributes).
  (def (write-stamped-screen (out : BufferedWriter) (screen : :t) (stamps : :u8vector)) => :void)
  ```

  It walks the leaves with `html-for-each`. The leaf where the tag name ends is written as two slices around the stamps; every other leaf is written whole. A screen not starting with `<` is written unstamped, as today.
- **Publishing** (`publish-screens!`, `:216-231`): a tab gets a new revision when `served`, `owed`, or `(not (or (eq? rendered tab.rendered) (equal? rendered tab.rendered)))`.
  - `eq?` decides for the html renderer, whose unchanged screen is the same object.
  - `equal?` is the content fallback that `string=?` was, for renderers that build a new value each time (the bare renderer, the counting renderer in `web-test.ss:30-37`).
  - `resend-screen!` (`:235-241`) only bumps the revision: the stamps are made at send, so it copies nothing.
- **The writer thread** (`stream-screens`, `:618-654`):

  ```scheme
  ([revision head screen]
   (unless (string=? head sent-head) (patch-elements session head))   ; unchanged
   (call-with-patch-elements session
     (lambda (out) (write-stamped-screen out screen (screen-stamps revision stream (fx1+ count)))))
   (lp revision head (fx1+ count)))
  ```

  - `await-screen` returns `[tab.revision self.head tab.rendered]`.
  - The head morph and heartbeats (`patch-signals session "{}"`) are unchanged and go through the same send path.
  - A failed write ends the stream, as today (`with-catch void`).
- **The page** (`page-html`, `new-page`, route `/`; `:286-309, 441-460, 496-502`) writes its prefix, the head, `<body>`, the stamped screen and its end into a memory `BufferedWriter`, and is served as those bytes. That is one copy per page load.
- **Other users of the type.** `render-screen` (`:154-158`) returns html, with the no-renderer screen as bytes. The bare renderer (`renderer/tests/support/bare-renderer.ss:63-69`) returns its `write-sxml` output as UTF-8. Its `<pre>` keeps newlines, so the translated path is exercised in tests.

## 4. Package versions and order

1. **gerbil-sse:** primitive, tests and README, committed on `main` in `/home/jay/Code/workbench-gerbil/gerbil-sse`. Check with `gerbil build` and `gerbil test -v 0 ./sse-test.ss`.
2. **gerbil-datastar** against the local sse. In the datastar clone, whose `.gerbil` is git-ignored:
   ```sh
   gerbil pkg link git.cons.io/jay/gerbil-sse /home/jay/Code/workbench-gerbil/gerbil-sse
   gerbil pkg build git.cons.io/jay/gerbil-sse
   gerbil build
   gerbil test -v 0 ./...
   ```
   Then run the conformance suite, and commit.
3. **Prototype measurement** (the plan's "measure a scratch prototype first"). In `scratch/drawing-4-bench/prototype`, send a 35 KB screen of 100 leaves through `call-with-patch-elements` to a discarding sink, against today's stamp, `patch-elements` and `sse-send!` path. Go on if the new path costs under about 50 µs.
4. **Push** gerbil-sse, then gerbil-datastar, to `main` (owner-authorized, STATUS 2026-10-22). Pushing is a separate step, so the review can stop before it.
5. **Tuna against the local clones before the push.** In this worktree, which has no `.gerbil` yet:
   ```sh
   gerbil pkg link git.cons.io/jay/gerbil-sse /home/jay/Code/workbench-gerbil/gerbil-sse
   gerbil pkg link git.cons.io/jay/gerbil-datastar /home/jay/Code/workbench-gerbil/gerbil-datastar
   gerbil pkg build git.cons.io/jay/gerbil-sse
   gerbil pkg build git.cons.io/jay/gerbil-datastar
   gerbil build
   ```
   `gerbil pkg link` symlinks into this worktree's `.gerbil/pkg` (`gxpkg.ss:267-271, 573-585`). The primary checkout's `.gerbil` is untouched.
   - **Do not run `make deps` while the links exist.** `pkg-install` fetches inside an existing package directory, and for a branch tag it runs `git pull origin main` (`gxpkg.ss:469-501`), here in the owner's clones.
   - **After the push:**
     ```sh
     gerbil pkg unlink git.cons.io/jay/gerbil-datastar git.cons.io/jay/gerbil-sse
     make deps
     ```
     Then run `make test` against the pushed packages before merging.
6. **Pinning. Primary agent decides; recommended: none.**
   - `depend:` accepts `pkg@tag`, and `gerbil deps -i` checks out that tag (`gxpkg.ss:390-415, 487-493`). A commit hash is not safe: a non-semver tag is followed by `git pull origin <tag>`. So pinning means pushing semver tags (`v0.2.0`) to both packages, and pinning sse in datastar's `gerbil.pkg`.
   - Without tags, Tuna follows `main` as it does now (`gerbil.pkg`). An existing `.gerbil` installed at `main` is updated by `make deps`: `main` is gxpkg's "frontier", which `pkg-tag-choose` keeps even over a pinned tag (`:534-544`). So pinning would not move the primary checkout anyway.
   - The primary checkout needs `make deps` after the merge.

## 5. Kernel, contracts, risks, steps

**The kernel is unchanged.** Changed modules, and what each imports:
- **renderer contract:** `render-screen` returns html; adds `html-for-each` and `html->string`; no new imports.
- **buffers contract:** a comment only.
- **`tuna/lib/memo.ss`:** diagnostics only.
- **renderer plugin:** no new imports.
- **web plugin:** imports `call-with-patch-elements`, through the same `:gerbil-datastar/http`.
- **Tests:**
  - the renderer test double;
  - the `render-screen` helpers in seven integration tests (`html->string`, except the `eq?` checks in `html-renderer-test.ss:204, 498, 537`);
  - `web-test.ss`.
- **`requires:` and contract imports** are unchanged everywhere.
- No contract serves one consumer: `html-for-each` serves any writer of html, and `html->string` serves the page and every test.

**Risks:**
1. A streamed error mid-event fails the session. In Tuna that ends the stream, as any send error does today.
2. **Found, pre-existing:** `write-sxml` passes CR and NUL through (checked: `(div "a\rb\x0;")` writes them raw). So a buffer whose text holds a CR fails every screen send, and the tab reconnects in a loop, today and after this stage. Recommended: a `TODO.md` entry now; escaping CR in the renderer is separate work.
3. **The scan's cost.** It is ~26 µs per 35 KB only with unchecked primitives; checked typed operations measured 8× slower. The prototype step settles it before the push.
4. Per-leaf interface dispatch, with about 2 to 4 leaves per drawn line and section. Measured in the bench.
5. Piece bytes are shared and must never be mutated. Nothing takes ownership of them: only the page's memory writer is taken with `get-memory-output-u8vector`, and it owns its own buffer.
6. **Test churn:** every screen-string assertion goes through `html->string`.

**Steps** (each leaves `make test` green, run as `systemd-run --user --scope -p MemoryMax=8G -p MemorySwapMax=0 timeout 1800 make test`):
1. gerbil-sse (§1).
2. gerbil-datastar (§2).
3. Prototype measurement (§4 step 3).
4. Push.
5. Tuna renderer: html, `markup->html`, contract, memo diagnostics, test helpers. The double-render test mode proves the bytes equal a drawing from scratch.
6. Tuna web: stamps, publishing, the writer thread, the page. New `web-test` cases:
   - a screen event's exact bytes (data-init before data-revision);
   - a multi-line screen from the counting renderer arrives as several `data: elements` lines;
   - an unchanged screen of equal content but a new object is not sent;
   - a re-send carries a new revision.
7. Unlink, `make deps`, `make test`.
8. **Bench.** `scratch/drawing-4-bench`, copied from `drawing-3-bench`, with `GERBIL_PATH` pointing at this worktree's `.gerbil`.
   - It adds "assemble and send per tab": render, then the web plugin's send code copied into `send-before.ss` and `send-after.ss` (stamps, `patch-elements` or `call-with-patch-elements`), into a discarding sink through `call-with-sse`. It reports milliseconds, bytes allocated and bytes sent.
   - Before at `f58772a` and after, for *long* (90/135: idle, key, `C-f`) and *mixed* (top and middle, 30/45: idle, key), with one and two tabs.
   - Each scenario's sent frames are saved and compared byte for byte, before against after.
   - Expected at about 35 KB: the send falls from about 0.3 ms to about 0.03 ms per tab.
9. **Stream byte equality, end to end.** Run `.gerbil/bin/tuna --port N --config starter/init.ss` at `f58772a` and after. A scratch script (curl) opens `/screen` for a fixed tab id, posts a fixed key sequence to `/commands`, and acknowledges each screen on `/applied` at once, within 15 s, so no heartbeat or re-send intrudes. Then `cmp` the two captured streams. Stop both processes by PID.
10. **Records:**
    - the renderer and web plugin headers;
    - the plan's status;
    - this note's "As built";
    - TODO: close the copying item, add the CR item;
    - the packages' READMEs, already done in steps 1 and 2.
