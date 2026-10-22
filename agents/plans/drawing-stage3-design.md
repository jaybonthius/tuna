# Design: drawing stage 3, lines and rows by value

**Status:** design for review (2026-10-22). Stage 3 of `agents/plans/drawing-only-what-changed.md`, under ADR 17, after stage 2 (`agents/plans/drawing-stage2-design.md`, including its "As built"). Nothing here is built yet. Line numbers are at `5aabc7c`.

**Where stage 2 left lines.** A text node is one piece, `(node V N)` with the run as input (`renderer/plugin.ss:182-199`). `render-text-node` (`:243-288`) draws every drawn line inside it, each time:
- it filters all highlights of the text (`:257-263`), then filters again per line (`:274-277`);
- `data-item` is `item-token` at the current character revision (`:281`; `buffers/contract.ss:870-881`), so every line's markup changes on every edit (audit H6);
- line ids are `line + offset`, from one pin per view and text node (`:97-101`, `:208-238`). So every line below an edit inside the run changes id.

## 1. The item piece

```scheme
;; renderer plugin, inside render-text-node
(memo ['line V N END REVISION]                    ; key: the line's identity in view V (§2)
      [END REVISION items? text faces cursor]     ; inputs: plain data
      draw-line)                                  ; (draw-line inputs) => :string, the line's <div>
```

**Inputs** (all plain data, `plain-value?`, `memo.ss:56-63`):

| Input | Meaning | How it is computed per drawn line |
|---|---|---|
| `END REVISION` | The line's birth (§2). It gives `data-item` `"N.END.REVISION"` and the element id `view-V-node-N-line-END.REVISION` | Looked up in the view's line births, a sorted vector |
| `items?` | Whether the text is drawn as items, so lines carry `data-item` and ids. A text drawn whole inside an item has neither (`:280-287` today) | From the node piece's run |
| `text` | The line's characters, a string | `text-line-start`, `text-line-end`, `text-substring` |
| `faces` | Face runs clipped to the line, relative to its start, overlaps resolved, faces remapped: `((START-COLUMN END-COLUMN . FACE) ...)` | One `text-highlights-in` query for the drawn range (§4), swept line by line. Then `remapped-face` (`renderer/contract.ss:40-42`) |
| `cursor` | `#f`, or `(COLUMN . CLASS)` with CLASS `"cursor"` or `"inactive-cursor"` | Only in the line holding the view's point (§3) |

The line's position (line number, absolute offsets) and the text's revision are not inputs. `faces` holds resolved runs, not raw spans: two span sets that draw the same faces are equal inputs, and these runs are exactly what `render-line` (`:293-324`) builds.

**What `draw-line` closes over.** Nothing but its inputs, apart from V's and N's ids, which its key identifies (stage 2's closure rule). It reads no source. So a line piece records no reads: it is current while its key's inputs are `equal?`, and the double render cannot disagree with it.

**How the text node piece composes line pieces.** The text node piece, `(node V N)`, draws every text node. Through `render-text-node`, it calls one derived piece and then one piece per line:

```scheme
;; render-text-node, for text node N in view V, lines FIRST..LAST
(let* ((lines (memo ['lines V N] [FIRST LAST items?]     ; value: a vector of [END REVISION items? text faces]
                    (lambda (inputs) (line-descriptors self v n inputs))))
       (cursor ...))                                     ; §3: view-node, view-point, selected-view
  `(div (@ (class "text"))
        ,@(map (lambda (d) ['*unencoded* (memo (line-key v n d) (with-cursor d cursor) draw-line)])
               (vector->list lines))))
```

**Recording strategy.** The text node piece does record the text. The plan anticipated this ("record per-line value checks instead of the text source") and it is acceptable:
- **The text node piece reruns on every edit of its text, and that is cheap.** Edits stamp the text's nodes anyway (`buffers/plugin.ss:86`). Rerunning computes inputs and compares values; it draws no line HTML unless a line's inputs changed. The cost is O(drawn lines) of slicing and `equal?`, against about 13 µs and 46 KB of allocation per line today (audit §5).
- **When nothing in its text, highlights or point changed, the piece is reused whole** (one check), as in stage 2.
- **The `['lines V N]` piece reads the text, highlights, face remapping and line births;** it does not read point. So `C-f` reuses its vector: the same string objects, so `equal?` succeeds through `eq?`. Only the cursor column is recomputed.

Rejected alternatives:
- **An untracked line accessor inside value-keyed items.** It hides a real dependency from ADR 17's automatic recording, and the double render cannot catch it, because the scratch drawing makes the same untracked read.
- **Per-line value checks recorded in place of the text source** ("backdating", Salsa style). `piece-current?` (`memo.ss:173-186`) is a pure check of recorded revisions. Backdating would make it re-execute children and compare their values. That is a deep change to `memo`, and it only saves the rerun for edits outside the drawn run. Revisit it if profiles show the rerun.

**Ancestors still redraw.** A parent embeds its child's HTML. So when a line changes, the text node piece and its ancestors run their draws again, and the *mixed* section renderers run once each. Their children are reused. Holes in the parents' HTML are stage 4's byte assembly, not this stage.

## 2. Line identity and tokens without the global revision (H6)

**A line's birth** is the pair `(END . REVISION)`: the line's end position at the character revision when the view first drew it. Line ids and tokens are both derived from it, so there is one identity:
- the token is `"N.END.REVISION"`;
- the DOM id is `view-V-node-N-line-END.REVISION`.

The token format and `token-item` (`buffers/contract.ss:884-901`) stay unchanged: "N.P.R names the line holding position P at revision R". A birth relocates through the journal with `relocate-position`, the rule `item-line` uses (`:827-831`). So `token-item` resolves a birth token to the line the renderer gave that birth. The end is used, not the start, as stage 2's pins do (`:93-96`). As a result:
- typing anywhere in a line, including at its end, keeps the line's birth;
- inserting `"abc\n"` at a line's start shifts its end, so the old content keeps its birth and the inserted line gets a new one;
- RET at the end of a line keeps that line's birth; the new line gets a new one;
- joining two lines puts both ends on one line, and the earlier birth keeps it.

**Line births, the successor of pins.** This is a renderer table, `view id → text node id → line-births`, shared by every client as pins are (stage 2 §3). Drawing only reads it.

```scheme
;; The births of the lines of a text node a view drew, at character revision REVISION:
;; ENDS, each line's end then, ascending; LINES, its line number then; BIRTHS, its birth.
(defstruct line-births ((revision : :fixnum) (ends : :vector) (lines : :vector) (births : :vector)) final: #t)
(defclass html-rendering ((pieces : memo-cache) (births : HashTable) (screens : HashTable)) final: #t)

;; The births of N's lines FIRST..LAST in V: a pure function of the table and the text.
(def (drawn-line-births (self : html-rendering) (v : view) (n : node) (first : :fixnum) (last : :fixnum)) => :vector)
```

How `drawn-line-births` works:
- It relocates the kept `ends` through `(text-changes-since t revision)`, typically one change. Ends stay ascending, because `position-after-change` is monotone.
- Each relocated end is mapped to its line now. Lines after a change shift by the change's newline count, so an unchanged text needs no `text-line-at`.
- When two entries land on one line, the first keeps it.
- Every drawn line without an entry is born now: `(its end . current revision)`.
- When the journal does not reach `revision`, every line is born now (the xi and Emacs fallback, prior art §5(a)).

**Births the journal no longer reaches.** A birth token is correct only while the journal reaches its revision. The default provider keeps 1,000 changes, trimmed to 500 (`buffers/plugin.ss:41, 89-97`); the toy keeps 100 (`toy-buffers.ss:52`).
- So `drawn-line-births` gives a line a new birth when `text-changes-since` returns `#f` for its birth revision. Reachability is monotone, so the check runs on the oldest birth first and costs one call when it passes.
- Lines re-born this way redraw once per journal trim (default: every 500 edits; toy buffers: every 100).
- `token-item` returns `#f` for a revision the journal no longer reaches; today it clamps to a wrong line. So a stale scroll report names nothing (`scrolling/plugin.ss:410` already handles `#f`) and never names the wrong line.

**The placement marker** sets `data-target` to its target line's birth token, through `drawn-line-births` for that one line, not `item-token` (`renderer/plugin.ss:381`). `tunaPlace` matches `data-target` to `data-item` by string (`web/web/tuna-input.js`), so the two must agree.

**After drawing** (replaces `pin-line-ids!` and `drop-unused-pins!`, `:224-238`, `:521-525`). When a client's screen is new (`:505-507`), `after-drawing!` walks the drawn runs as it does now, which includes text nodes drawn whole. For each text node it stores:
- the relocated entries;
- the births of the lines drawn, with the current revision.

`client-screen` (`:104-106`) keeps each client's drawn births per view and text node instead of view ids. Entries no client's last screen drew are dropped; so are the views of a client that goes (`:552-556`).

**Why the table needs no source** (stage 2's argument, extended). Call the table S, the current revision R, and the stored table S′. Then `drawn-line-births` gives the same births for every line from S′ as from S:
- relocation composes;
- collisions are already resolved at R;
- lines without an entry are born `(end . R)` either way;
- the only entries dropped are lines in no client's last screen.

So no current piece's output changes. In test mode, `after-drawing!` recomputes the drawn births and fails if any differ.

**This fixes stage 2's open consequence:** an edit between two tabs' anchors no longer renumbers the lines on one side, because each line has its own birth.

## 3. Point and selections as per-line inputs

- **Point's source (stage 2, `view.point-changes`) stays.** Only `view-point` reads it (`buffers/contract.ss:1125-1135`). Two places call it:
  - `render-text-node`, only when `(eq? n (view-node v))`. It then reads `selected-view` for the cursor class; today it reads that for every text node (`:247-248`).
  - The status line in the view piece (`renderer/contract.ss:47-60`).
- **The cursor reaches only its line's inputs.** `C-f` makes the focused text node piece stale. That piece reruns and reuses `['lines V N]`, and one or two line pieces have new inputs. Its ancestors run their draws (§1) but call no line renderer.
- **Selections.** Only the primary selection exists, as point (ADR 6). The `cursor` input is where selection columns go when selections are drawn. No other mark is built now.
- **A hazard this stage exposes:**
  - `view-node` and `view-showing` record `view.changes`, which `place-view!` and `set-view-scroll!` change on every scroll (`:1238-1256`).
  - So every text node piece in a view, and its `['lines V N]` piece (it reads `view-showing` for face remapping), reruns on any scroll, even with an unchanged run.
  - A third view source for the placement, read only by `view-placement` (`:1192-1194`), would stop this.
  - **Primary agent decides** whether that belongs in this stage (recommended only if the bench shows scroll cost; the bench does not measure scrolling today).

## 4. Highlights

**Changed ranges at `set-highlights!`.**

```scheme
;; Buffers interface (replaces set-highlights! and text-all-highlights, contract.ss:355-357)
(set-highlights! (t : text) (name : :symbol) (spans : :list) (start : :fixnum) (end : :fixnum)) => :void
(text-highlights-in (t : text) (start : :fixnum) (end : :fixnum)) => :list
;; dispatchers
(def (set-highlights! (t : text) (name : :symbol) (spans : :list)
                      start: (start : :fixnum := 1) end: (end :? :fixnum := #f)) => :void) ; END #f: the end of T
(def (text-highlights-in (t : text) (start : :fixnum) (end : :fixnum)) => :list)  ; records T's source
```

- **`set-highlights!` replaces layer NAME's spans inside START..END only.** A span crossing an edge keeps its part outside, and new spans are clipped to the range. The defaults replace the whole layer, as today.
- **Cutoff (both providers, a contract promise).** When the layer's spans inside the range are equal, by start, end and value, to the new ones, nothing changes: no source change, no decoration revision, no stamped node. The comparison is O(spans in range), less than any redraw. Today an identical layer costs 5.6 ms producing an identical screen (audit §5).
- **`text-highlights-in`** returns every layer's spans that overlap START..END, in the provider's layer order (unspecified, as today), and by start within a layer. `text-all-highlights` is deleted. Its users switch: the renderer and `buffers-contract-test.ss:147, 317`.
- **The default provider's index.** Each layer is a vector sorted by start, plus a running maximum of ends. A query binary-searches the first span whose running maximum passes START, then scans to the first span starting at or after END.
  - `set-layer!` (`buffers/plugin.ss:162-171`) sorts once.
  - `relocate-decorations!` (`:177-183`) keeps the order, since `span-after-change` is monotone. It already walks every span, so it rebuilds the running maxima at no extra cost.
  - The toy provider keeps its hash of lists and filters linearly (`toy-buffers.ss:160-167`). That differs on purpose, so the contract tests prove the behaviour.
- **No changed-range log for drawing.** The `['lines V N]` piece reruns on a highlight change, and per-line `faces` compared by value redraw only the lines whose faces changed. This is CodeMirror's `RangeSet.compare`, done per line (prior art §5(c)4). A recorded range is needed only by drawers that compare nothing, which ADR 17 rules out.

**Asynchronous results.**

```scheme
;; buffers contract: spans for START..END of a layer, as a job computed them
(defstruct ranged-spans ((start : :fixnum) (end : :fixnum) (spans : :list)) final: #t)
;; RESULT moved through CHANGES: a span list (rebase-spans), or a ranged-spans whose range
;; moves as a span does; #f when the range is empty afterwards.
(def (rebase-job-result (result : :t) (changes : :list)) => (Maybe :pair))
```

- Both providers' `job-rebase` (`buffers/plugin.ss:56-59`, `toy-buffers.ss:64-67`) call `rebase-job-result` in place of `[(rebase-spans result changes)]`.
- A ranged highlighter's `apply:` calls `(set-highlights! t name spans start: s end: e)` with the rebased range. Text inserted at either edge after the job started stays outside the range, so its spans are left as relocated.
- The digit highlighter (`tests/support/digit-highlighter.ss:65`) still posts whole-text span lists. The cutoff, and per-line faces compared by value, already confine its redraw to the changed lines.

## 5. Rows and other items

There is no special case:
- A node that opens into children has nodes as items, and each is already a `(node V N)` piece keyed by identity, with its run as input (stage 2).
- A row is redrawn only when its node's source changes, and `set-node-attribute!` stamps nothing for an equal value (stage 1).
- *mixed* sections and stage 5's process rows are covered as they are.

Only lines lacked identity and value inputs, because a line is not a node; this stage gives them both.

**A cost left in place:** after an edit, the *mixed* root still recounts its 4,000 children's items in `children-items-of` (`buffers/contract.ss:750-768`), 1.6–1.8 ms (audit; `drawing-2-bench/after.txt`). That is state-side, not drawing (audit seam 8). It will dominate *mixed*'s key cost after this stage. It needs its own decision.

## 6. Pins, re-anchoring, per-client runs

- Line births replace pins entirely (§2). `line-ids`, `pin-of`, `line-id-offset`, `line-run-of`, `pin-line-ids!`, `drop-unused-pins!` and the `pins` field are deleted.
- `line-run` loses `id-offset` and gains the renderer (`rendering : html-rendering`) and `items?`. Every text node's piece binds it, so `render-text-node` reaches the births and a text drawn whole has line pieces too.
- **Tabs.** No line piece and no `['lines V N]` piece reads a per-client source:
  - two tabs drawing the same line with equal inputs share one variant;
  - two runs of one node keep one `['lines V N]` variant each (`memo.ss:224-228`);
  - the per-client mark and sweep keeps a line piece while some client's last pass used it.
- **Keys are unique in a pass.** Births are unique among a text's current lines in one view (§2 rules), and V is in the key, because two views may give a line the same birth.

## 7. Kernel, contracts, risks, steps

**The kernel is unchanged.**

**Modules changed:**
- `tuna/lib/memo.ss`: `current-memo-draw-observer`, a parameter called with each key drawn through a cache (not from scratch). It is for tests and the bench, which must count line pieces drawn inside the renderer.
- **buffers contract and both providers:**
  - ranged `set-highlights!` with the cutoff;
  - `text-highlights-in` replaces `text-all-highlights`;
  - `ranged-spans` and `rebase-job-result`;
  - `token-item` returns `#f` past the journal;
  - Items documentation for birth tokens.
- **renderer plugin:** line pieces, the lines piece, line births, the placement token, `after-drawing!`.

No contract is shaped for one consumer:
- `text-highlights-in` serves every drawer and any range query;
- the `token-item` fix serves every token reader;
- `ranged-spans` serves every ranged job;
- the observer serves tests and benches.

Imports and `requires:` are unchanged in every module.

**Risks:**
1. Re-birth past the journal redraws those lines once per trim. A report naming a just-trimmed birth is ignored once.
2. The identity rules (§2) give a line split by RET in the middle a new birth for its first half. That costs a morph, not wrong content.
3. Every edit reruns the text node piece, O(drawn lines) of slicing and `equal?`. Ancestor renderers rerun (§1).
4. `children-items-of` recount in *mixed* (§5), and `relocate-decorations!` at O(spans) per edit (0.8 ms with 50,000 spans, audit §5), remain.
5. One very long span early in a layer makes queries scan from it.
6. About 230 more pieces per pass make a no-change redisplay walk more marks (`mark!`, `commit!`, `memo.ss:189-192, 264-275`). This is estimated at tens of µs, and idle still draws nothing.
7. **"Three cursors" cannot be tested as written: Tuna has no multiple cursors.** Recommended substitute: three views of one buffer, each point a cursor. **Primary agent: confirm.**
8. The births table is read while drawing without a source. This rests on §2's invariant, asserted in test mode.

**Steps.** Each step leaves `make test` green under `systemd-run --user --scope -p MemoryMax=8G -p MemorySwapMax=0 timeout 1800`. Test mode (the double render) is on in every test kernel.
1. **`memo.ss` observer.** Test in `memo-test`: the observer sees pieces drawn, not pieces reused, and not the scratch drawing.
2. **Highlights** (buffers contract, default and toy providers). Cases in `buffers-contract-test.ss`, which runs both providers:
   - a ranged set keeps spans outside the range and clips at its edges;
   - identical spans change no source (`drawn-again?` ⇒ `#f`), and different spans do;
   - `text-highlights-in` returns exactly the overlapping spans;
   - a job's `ranged-spans` rebased past an edit replaces only its moved range;
   - a range deleted by an edit drops the result;
   - `token-item` returns `#f` for a revision the journal no longer reaches.
   - Update `editor-test.ss:85-95` and the existing highlight cases.
3. **Line pieces and births** (renderer). New `html-renderer-test` cases count `'line` keys through the observer:
   - a key redraws one line;
   - `C-f` within a line redraws one, and across lines two;
   - three views of one buffer: `C-f` in one redraws one of its lines and none of the others' (pending risk 7);
   - a key typed in one view of a buffer shown in three redraws that line once per view;
   - inserting a line above the drawn run redraws no line;
   - RET at the end of a drawn line redraws that line and draws the new one;
   - a highlight result that changes one line's spans redraws one line;
   - an identical result redraws none and returns the same screen string (`eq?`);
   - the placement marker's `data-target` equals its line's `data-item` after an edit above;
   - a line kept past the toy buffers' 100-change journal gets a new birth, and its old token resolves to `#f`.

   Then:
   - Rewrite the three line-id tests (`html-renderer-test.ss:691-749`) to compare a line's id before and after the edit, not fixed numbers.
   - Run the counting cases again with `string-text-store` (the toy text store) in place of `rope-text-store`.
4. **Bench.** Copy `scratch/drawing-2-bench` to `scratch/drawing-3-bench`, with `GERBIL_PATH` pointing at this worktree's `.gerbil`. Add a line-pieces-drawn count (the observer), "a highlight result changing one line", and "three views".
   - Run it at `5aabc7c` and after this stage, for *long* (90/135) and *mixed* (top and middle, 30/45): idle; key; `C-f`; three views; +digits key; a changed-line result; an identical result; one and two tabs.
   - Expected for *long*: key and `C-f` well under 1 ms, from about 3 ms; an identical result at about 0, from about 5.6 ms.
   - Expected for *mixed*: key still dominated by the recount (§5).
5. **Records:** the renderer header (`renderer/plugin.ss:12-78`), the buffers Items documentation (`contract.ss:707-726`), the plan's status line, and this note's "As built".
