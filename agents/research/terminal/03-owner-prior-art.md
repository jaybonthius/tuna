# Terminal: the owner's earlier work, and what Tuna can take from it

Read-only survey, written 2026-10-27, for the `terminal` plugin built on libghostty-vt (the virtual-terminal library taken from the Ghostty terminal). It is evidence, not a decision. Line numbers are as of this date.

Terms used below:
- **PTY** (pseudo-terminal): the kernel device pair a shell runs on; Tuna holds the "master" side, reads the program's output from it and writes keys into it.
- **VT**: the escape-sequence language terminals speak. **OSC** (Operating System Command) and **SGR** (Select Graphic Rendition, colours and bold) are two families of it.
- **KKP**: the Kitty keyboard protocol, which reports key releases and modifiers more precisely than legacy encodings.
- **SSE** (Server-Sent Events): the one long-lived HTTP stream Tuna draws screens over. A **fat morph** is a Datastar patch of the whole screen.
- **FFI** (foreign-function interface): calling C from Gerbil.

## Summary

1. **`gerbil-libghostty` is the binding to use, and it is nearly complete.** It covers writing, full render frames, key and mouse encoders, OSC/SGR parsers and terminal effects (clipboard, title, bell, replies), persistent snapshots, and selection. It has 129 passing tests on Linux x86-64. The checkout has **no commits**. It builds only from a pinned Ghostty commit with Zig 0.16.0, and it links by absolute path to its own build folder. It is not a Tuna dependency yet.
2. **Its render frame always copies the whole grid**, about 1 ms and 1.5 MB of allocation for 80×24, and about 4.6 ms and 6 MB for 160×48. Tuna's per-row `memo` saves the HTML, but not this copy. A "copy only dirty rows" call does not exist; the binding's own notes say it needs a separately approved API design.
3. **All earlier designs agree on four points.** The server owns everything. The browser sends raw key, paste, pointer, wheel and size facts. libghostty, not the browser, encodes them against the live terminal modes. Rendering is latest-state and frame-paced (16–33 ms), never a queue of frames.
4. **Two shared lessons for HTML rendering.** Merge adjacent cells with the same style into one span. Colour palette cells through CSS custom properties, not literal RGB. Tuna's rule of "no colours in Gerbil" makes 24-bit colour an owner decision, as it was in weevil.
5. **Nobody finished persistence or reconnection.** shux lists "Restore terminal state after reconnecting" as open. The Gerbil binding has the pieces (snapshot to bytes and back), but no application has used them.
6. **Threads.** Tuna's jobs are Gambit green threads in one operating-system thread, so running VT parsing "off-thread" buys no parallelism. The PTY reader should be a job that waits on the port and posts byte chunks. Parsing and frame copying belong on the editor thread, in the job's `apply`.

## 1. gerbil-libghostty (`/home/jay/Code/workbench-gerbil/gerbil-libghostty`)

### What it is and how mature

- Typed Gerbil bindings pinned to Ghostty `befcdfd2c3a1cb24d9ec886e93c95b2b5daa7028` (`native/GHOSTTY_COMMIT`). Every behaviour family of the owner's Racket binding is implemented and tested; only Linux x86-64 has been built (`README.md:3`). The parity matrix lists every family as "Implemented" (`PARITY.md:5-19`), with 129 cases and 1020 checked header facts about the C interface (ABI, application binary interface) (`README.md:21`, `PARITY.md:27`).
- `git log` reports "your current branch 'main' does not have any commits yet". The build therefore uses `gxi build.ss`, not `gerbil build`, because the package front end wants Git history (`README.md:19`, `Makefile:15-17`). This matters for Tuna: `gerbil build` needs at least one commit (Tuna `AGENTS.md`, Commands).
- Explicitly out of scope: browser/PTY applications, macOS, ARM64, and new upstream features such as unknown-OSC capture and selection gestures (`PARITY.md:21`, `PARITY.md:45`).

### Public API (all from `:gerbil-libghostty/ghostty`, `ghostty.ss:6-160`)

| Area | Procedures | Notes |
| --- | --- | --- |
| Terminal | `make-terminal` (`ghostty.ss:291`), `terminal-write!` (`:335`), `terminal-write-until-ground!` (`:360`), `terminal-resize!` (`:348`), `terminal-reset!`, `terminal-close!`, `terminal->plain-text` (`:732`) | Writes take a `u8vector` slice; split UTF-8 and escape sequences carry over between writes (`ghostty.md:31-39`). |
| Render frames | `terminal-render-snapshot` (`ghostty.ss:1567`) | One detached frame: columns, rows, dirty (`clean`/`partial`/`full`), colours with a 256-entry palette, cursor, a vector of rows with per-row `dirty?` and selection range, cells with grapheme, width, style, resolved colours and `selected?`, plus Kitty images (`ghostty.md:97-107`). **It always copies the complete grid** (`ghostty.md:99`). |
| Key input | `key-event` (`ghostty.ss:1886`), `make-key-encoder` (`:1979`), `key-encoder-encode` (`:2083`) | 176 physical keys; `terminal:` keyword syncs encoder options with the live terminal modes at encode time (`PARITY.md:16`). |
| Mouse input | `mouse-event`, `make-mouse-encoder`, `mouse-encoder-set-size!`, `mouse-encoder-encode` (`ghostty.ss:2092`) | Pixel to cell conversion uses the browser-measured geometry. |
| Paste and reports | `paste-safe?`, `paste-encode` (`ghostty.ss:2286`), `focus-encode`, `size-report-encode`, `color-scheme-report-encode` | `paste-encode` does not refuse unsafe text; the caller decides policy (`ghostty.md`, utilities table, `paste-encode` row). |
| Modes | `terminal-modes`, `terminal-mode-enabled?` (`ghostty.ss:2549`) | 42 named modes, e.g. `bracketed-paste`, `alt-screen`, mouse modes, `in-band-resize`. |
| Effects | `terminal-set-pty-write-handler!`, `…-title-changed-…`, `…-pwd-changed-…`, `…-bell-…`, `…-clipboard-write-…`, `…-desktop-notification-…`, `…-progress-…`, `…-size-…`, `…-color-scheme-…`, `…-device-attributes-…` (`ghostty.ss:1060-1071`) | Handlers run **synchronously inside `terminal-write!`**, get copied bytes, and must not raise past native code (raises are recorded and re-raised afterwards) (`ghostty.md:51-66`). Clipboard writes arrive as OSC 52 `clipboard-write` values; there is no clipboard read (`ghostty.md:61`). |
| OSC/SGR parsers | `make-osc-parser`, `osc-parser-feed!`, `osc-parser-end!`, `make-sgr-parser`, … | Standalone parsers, not tied to a terminal (`ghostty.md`, "Reusable OSC and SGR parsers"). Tuna probably needs them only for its own uses, not for the terminal. |
| Snapshots | `terminal->snapshot-bytes`, `snapshot-bytes->terminal` (`ghostty.ss:423-428`), port and incremental decoder forms | Restore screens, scrollback history and unfinished parser state; **selections are not saved** (`ghostty.md`, "Persistent snapshots"; `ghostty.md:93`). |
| Selection | `terminal-set-selection!`, `terminal-select-word!`, `terminal-select-line!`, `terminal-select-output!`, `terminal-selection->plain-text`, … | Terminal-owned selection with soft-wrap-aware copy (`ghostty.md:80-93`). Ghostty's newer gesture API is not bound (`ghostty.md:93`). |
| Grid references | `terminal-track-grid-reference` and friends | Positions that follow scrolling and reflow; also the only way to read a hyperlink's URI (`ghostty.md:72-76`). |

### Threading: the callback gate

- One library-wide mutex, the "native entry gate" (`ghostty.ss:210`), serialises every operation that can call back into Scheme. Gambit's manual warns that overlapping Scheme→C→Scheme calls on different Scheme threads can corrupt C frames (`ghostty.md:19-25`).
- Consequences for Tuna (`README.md:37`, `ghostty.md:23-25`):
  - a slow effect handler blocks every other terminal;
  - a handler must never wait on another thread that wants the gate;
  - escaping a handler with a continuation, or killing its thread, is unsupported.
- Each terminal also has its own mutex. Same-object reentry from a handler raises instead of blocking (`ghostty.md:15-17`).
- Rule for Tuna: handlers only append to a queue. The demo does exactly this. Its PTY reply and bell handlers push onto lists (`examples/browser-terminal/app.ss:68-71`), which are drained after `terminal-write!` returns (`app.ss:15-24`, `app.ss:36-37`).

### Build and packaging

- Needs Zig **0.16.0** exactly, Linux x86-64, Git, a C compiler, Make, Python 3 for ABI checks (`scripts/build-native.sh:7-11`, `README.md:7`). `make native` shallow-fetches the pinned commit into `.build/ghostty-source` and builds `libghostty-vt.so` with `-Doptimize=ReleaseFast -Dcpu=baseline` into `.build/ghostty-prefix` (`scripts/build-native.sh:13-26`).
- The compiled FFI module links with an **rpath to that checkout's prefix** (`build.ss:9-10`); "moving the checkout requires rebuilding" (`README.md:19`).
- Packaging options for Tuna, none tried yet:
  1. Commit the binding, then depend on it through Tuna's `make deps`. The `.so` and its rpath must then come from a build step inside `.gerbil/` (the same pattern as `gerbil-parakeet`).
  2. Vendor nothing and have Tuna's Makefile run the binding's `make build` in place.

  Either way the terminal plugin needs a native prerequisite that today's `make deps` does not provide. go-web-terminal solved the same problem with an installer command that builds into a chosen prefix and emits a `pkg-config` file (`/home/jay/Code/go-web-terminal/README.md:5-11`; `CONTEXT.md:25`).

### Measured cost (Gerbil `-O`, `PARITY.md:252-261`)

| Workload (100 operations) | Time | Allocated |
| --- | --- | --- |
| 8192-byte writes | ~1.1 ms total | ~1 MB |
| 80×24 full frames | ~0.10–0.12 s (about 1.1 ms per frame) | ~150 MB (about 1.5 MB per frame) |
| 160×48 full frames | ~0.44–0.47 s (about 4.6 ms per frame) | ~610 MB (about 6 MB per frame) |

VT parsing is cheap; copying frames into Scheme is the cost. "Consumers needing lower allocation rates require a separately approved API design, not borrowed views or hidden mutable caching" (`PARITY.md:37`).

### The browser-terminal example (`examples/browser-terminal/`)

A fixed one-second script, not an interactive shell (`README.md:3`, `README.md:24-30`). What is worth reusing:

- **PTY ownership.** A small C helper (`native/pty-process.c`) owns the PTY master and the child's process group. Gerbil talks to it over ordinary process ports with tiny framed packets: `w` + length for input, `r` + four sizes for resize, `q` to stop (`pty.ss:58-81`, `pty.ss:87-100`). The reason given is that the installed Gambit's own PTY option is broken and its child reaper competes (`README.md:28`). **This is the most important finding for Tuna's process library**: plain `open-process` with `pseudo-terminal: #t` should not be assumed to work.
- **Input path.** `input-adapter.js` sends ordered facts as JSON: key down/up with `code`, `key`, modifiers including CapsLock/NumLock, paste, pointer, wheel, and measured cell geometry (`input-adapter.js:7-66`). The server maps `KeyboardEvent.code` to a libghostty physical key (`app.ss:115-134`), checks text with grapheme width (`app.ss:135-138`), and encodes with `terminal:` sync (`app.ss:183-193`). Paste uses `paste-encode` with the live bracketed-paste mode (`app.ss:194-198`).
- **Wheel routing.** If mouse tracking is on, send buttons 4/5. If the alternate screen has alt-scroll on, send arrow keys. Otherwise scroll the viewport (`app.ss:208-222`). This is the same three-way rule as shux (below).
- **Resize.** Columns and rows come from browser-measured pixels. The code resizes the PTY, the terminal and the mouse encoder, and sends an in-band size report when mode 2048 is on (`app.ss:151-170`).
- **What not to copy.**
  - The reader polls the port every 5 ms while holding a lock (`app.ss:25-46`).
  - The renderer writes every cell as its own `<span>` with inline `style="color:rgb(…)"` (`render.ss:72-99`, `render.ss:151-168`). That breaks Tuna's HTML rule and makes the HTML large.
  - The whole frame is redrawn whenever a revision counter moves (`app.ss:232-241`).

## 2. go-web-terminal (`/home/jay/Code/go-web-terminal`)

A Go library that runs a PTY-backed terminal in a Datastar page; the host application owns HTTP (`README.md:1-3`).

- **Process ownership.** "Terminal process" means the leader and every descendant still in its dedicated operating-system session. When the leader exits, the job ends, but the terminal and its last screen stay until the host closes it (`CONTEXT.md:7`, `CONTEXT.md:11`). The PTY starts with `pty.StartWithSize` (`terminal_linux.go:740`). Shutdown scans the session and escalates HUP, TERM, then KILL using pidfds, so a recycled process id cannot be signalled by mistake (`terminal_job_linux.go:334-613`, `terminate` at `:557`). A program that calls `setsid` leaves ownership on purpose.
- **Rendering to HTML.**
  - Each change produces a complete current rendering of the viewport, not a diff (`CONTEXT.md:15-17`, `api.go:98-103`).
  - Rows are rendered from Ghostty's render state with Templ. **Adjacent cells merge into one span** when their style, colours, link and cursor match (`renderer_linux.go:416-429`).
  - Palette colours are written as `var(--gwt-pN)`, and default foreground and background as CSS variables (`renderer_linux.templ:139-151`). Themes therefore change in CSS, not in the server.
- **Frame pacing.** The default render interval is 1/30 s (`options.go:14`). Output marks the render dirty and arms a timer for the time remaining in the interval (`terminal_linux.go:1013-1021`, `terminal_linux.go:1122-1131`). Several outputs inside one interval cost one render.
- **Clipboard and links are terminal events.** OSC 52 writes become `ClipboardWriteEvent{Text}` (size-capped, plain text only) (`terminal_linux.go:152-182`). A validated hyperlink click becomes `OpenLinkEvent{URL}` (`api.go:79-96`). Events are delivered with the rendering that caused them and are never replayed (`CONTEXT.md:21`). The host decides whether to honour them.
- **Browser input** is a sealed family of typed commands: key, paste, resize, colour scheme, wheel, pointer button/motion/reset, focus, context menu (`command.go:51-170`). The key command carries `Key`, `Code`, `Location`, `Repeat`, `IsComposing`, modifiers including AltGraph/CapsLock/NumLock, and a copy-shortcut flag (`command.go:40-61`).

## 3. shux and its libghostty spike (`/home/jay/Code/shux`)

shux itself is a server-rendered browser multiplexer whose Core holds application state; its terminal work lives in `spikes/libghostty-terminal` (`shux/README.md:1-3`, `spikes/libghostty-terminal/README.md:1-21`). The spike sent "Tuna-shaped keydown values" through a "Tuna action" (`README.md:17-21`). That is direct prior art for Tuna's input path.

- **Viewport row rendering.**
  - `viewportRenderer.renderRow` walks only the visible rows of Ghostty's render state.
  - It skips wide-character spacer tails and reads graphemes into a reused buffer.
  - It resolves selection and cursor colours on the server, and looks up hyperlink URIs only for cells flagged as links (`viewport.go:143-253`, `viewport.go:443-460`).
  - `appendTerminalCell` merges runs with equal class, style and link (`viewport.go:255-269`).
- **Performance findings** (`PERFORMANCE.md:250-299`):
  - A full 120×36 patch costs 6.0 ms; 240×72 costs 25.6 ms. Cost grows linearly with cells.
  - Allocation leaders are formatting, style reads, `renderRow` and class strings.
  - VT ingestion of a 39 KB ANSI-heavy corpus costs 0.6 ms.
  - The browser was 98% idle.
  - Recommended next target: per-cell patch construction and repeated render-state crossings.
  - Judged not worth it: modifying Ghostty, or claiming a browser bottleneck.
- **Frame pacing and wheel input.** Invalidation is edge-triggered and latest-state, with at most one patch per 16 ms. Wheel samples older than 100 ms are dropped. Commands never wait for a morph (`scrolling-research.md:3-16`, `scrolling-research.md:184-197`).
- **Keyboard findings** (`keyboard-research.md:5-25`).
  - The browser sends facts; the Core refreshes encoder options from terminal state before every encode.
  - AltGraph needs Ctrl and Alt marked as consumed, or AltGr letters become control characters.
  - Without a layout map, the unshifted codepoint is set only from evidence.
  - Composition and IME (input method editor) input is deferred.
  - Paste uses the trusted `paste` event on a focused element, with Ctrl+V (Cmd+V on macOS) left to the browser.
- **Selection** uses one libghostty selection gesture per pointer press. Autoscroll runs on a 15 ms server ticker, and copy-on-select is configurable (`README.md:25`).
- **Persistence: none.** "Support multiple terminal sessions" and "Restore terminal state after reconnecting" are unchecked (`TODO.md:21-22`).

## 4. weevil (Racket) research (`/home/jay/Code/weevil-terminal/plans/`)

Phase 1 was finished on 2026-06-17: a real libghostty terminal in weevil over SSE, verified with fish and bash (`terminal-design.md:19-53`). What it concluded:

- **The PTY is easy.** `openpty` through FFI, plus `subprocess`, plus `setsid -c`, with no `fork` (fork is unsafe in threaded Racket) (`terminal-research/04-pty-in-racket.md:16-20`, `:264-268`).
- **The engine choice moved to libghostty-vt through direct C FFI.** Brief 06 thought a Zig shim was needed. Brief 07 proved that the C `render_state` row and cell accessors read the styled grid directly (`terminal-research/07-libghostty-ffi-proven.md:91-113`, `terminal-design.md:63-75`). A fake engine kept unit tests free of the native library.
- **"The emulator is the coalescer"** (`terminal-design.md:248-271`, `:80-85`):
  - feed PTY bytes immediately and drop them;
  - flush on an ~8 ms debounce with a ~33 ms hard cap;
  - flush at once after a key is written, so echo looks instant.
  - Frame dropping comes free, because each flush reads the current state.
- **Rendering** (`terminal-design.md:288-323`):
  - one `div` per row with run-length spans, and classes for the 16+256 palette;
  - a terminal-pane-scoped patch, with per-dirty-row patches considered for large grids;
  - scrollback as virtual-scroll rows;
  - the alternate screen as a fixed grid.
- **Truecolor vs "no inline styles"** needed an owner decision. The recommendation was a CSS custom property on 24-bit cells only (`terminal-design.md:410-417`). Phase 1 shipped with colours quantised to 256 (`terminal-design.md:44-46`).
- **Input modes as in eat/vterm.** The default is semi-char: most keys go to the child and an editor prefix stays reserved. Char mode sends everything, with one escape key (`terminal-design.md:325-342`, `:434-439`).
- **Crash isolation.** A native fault kills the whole virtual machine. The recommendation was an out-of-process worker for multi-session servers (`terminal-design.md:419-426`); it was not built (`terminal-design.md:50-52`).
- **Left unfinished:** sizing from the pane (fixed 80×24), scrollback, OSC 7 working directory, truecolor, and mouse, selection, clipboard and links (`terminal-design.md:44-52`).

## 5. Other repositories in `/home/jay/Code`

- **ghostty-web**: Coder's WebAssembly build of Ghostty's parser behind an xterm.js-compatible browser API. It is a client-side terminal, the opposite of Tuna's model.
- **go-libghostty**: Mitchell Hashimoto's cgo bindings for libghostty-vt, statically linked. go-web-terminal and the shux spike use them.
- **libghostty-rs**: Rust FFI and safe wrappers (Terminal, RenderState, KeyEncoder, MouseEncoder).
- **libghostty-vt-node**: Coder's Node-API binding: feed bytes, resize, read plain text and styled cell snapshots.
- **pyghostty**: complete unofficial Python bindings, including scrollback snapshots and Kitty graphics.
- **racket-libghostty**: the owner's contracted Racket binding, pinned to `51ed437c…`. It is the reference that gerbil-libghostty matched (`gerbil-libghostty/PARITY.md:3`).

## 6. Mapping to Tuna

### Rendering a grid through Tuna's renderer

- **A terminal is one buffer node** of a new kind, with one item per visible grid row. Each row is drawn through `memo` (ADR 17 `0017-memo-and-sources.md:35-39`), and the screen is still one fat morph (ADR 7 `0007-rendering-and-transport.md:20`).
- **Where the frame is copied.** `terminal-render-snapshot` mutates native dirty state (`ghostty.md:97`). ADR 17 forbids writes while drawing (`0017-memo-and-sources.md:41-42`). So the plugin calls it outside drawing, in its apply step:
  1. Convert each row to plain data: a list of runs `(text classes colour-refs)`, merged as in `renderer_linux.go:416` and `viewport.go:255`.
  2. Compare each row with the last copy using `equal?`.
  3. Stamp a per-row source only for rows that differ. This is ADR 17's equality cutoff (`0017-memo-and-sources.md:43-46`).
- **What a row piece reads.** Its inputs are its run list plus the cursor columns on it. Typing a character then redraws one or two rows, as for text lines.
- **Row identity.** ADR 17 says a piece's key is "never a position" (`0017-memo-and-sources.md:37`). Grid rows are positional by nature (row *y* of the viewport is the identity). With rows compared by value, keying on `(terminal-id, y)` is safe; record this as a deliberate exception. Scrollback rows, if drawn as items, need stable ids instead. Grid references or Ghostty's history coordinates could supply them.
- **Colours** (`agents/guides/html-css.md`; ADR 7 `0007-rendering-and-transport.md:27-28`):
  - Palette indices become classes or `var(--terminal-pN)` tokens in the plugin's `tokens.css`, and themes replace them.
  - Bold, italic, underline, strike, inverse, faint and invisible become classes.
  - Inverse is resolved on the server or with a class.
  - **24-bit RGB has no class.** It needs either a per-span custom property (`style="--fg:#rrggbb"`) or quantising to 256. This is an owner decision, as in weevil.
- **Cell grid vs ADR 7.** ADR 7 says the core must not assume a fixed-width grid (`0007-rendering-and-transport.md:23`). A terminal node is a local monospace grid inside one node, which does not conflict with that rule. The browser still measures cell size and reports columns and rows, the way scrolling already reports measurements (ADR 15).
- **Cost to watch.** The full-grid copy (1–5 ms and 1.5–6 MB per frame, above) happens before `memo` can help. Two ways to reduce it:
  - Pace frames: copy at most once per 16–33 ms, with a Tuna timer or by copying only when a redisplay is due.
  - Later, add a binding call that copies only rows whose native `dirty?` is set. The binding's notes flag that this needs API design (`PARITY.md:37`).

  shux's Go numbers (6 ms for 120×36 HTML) suggest HTML generation per changed row, not parsing, is the main server cost (`PERFORMANCE.md:256-266`).

### Browser keys to the key encoder, and which keys Tuna keeps

- **Fields already present.** Tuna's `key-event` already carries `key`, `code`, `location`, `repeat?`, `composing?`, the modifiers and `alt-graph?` (`plugins/keys/contract.ss:106-122`). That is what `key-event` plus `key-encoder-encode … terminal:` needs. The `code` → physical-key mapping can come from `examples/browser-terminal/app.ss:115-134`. AltGraph needs the consumed-modifier rule from `shux/spikes/libghostty-terminal/keyboard-research.md:9`.
- **Missing compared with prior art.**
  - There is no key-up, so KKP release reporting (flag 2) cannot be honoured.
  - There are no CapsLock/NumLock facts (`input-adapter.js:18-22`; `keyboard-research.md:7`).
  - Either the web plugin sends them, or Tuna documents the limit.
- **Paste** already arrives as `paste-event` under `<paste>` (`plugins/keys/contract.ss:209-215`). The terminal binds `<paste>` to a command that checks `paste-safe?` and calls `paste-encode` with the live bracketed-paste mode.
- **How keys reach the terminal.**
  - The terminal node's keymap gets a catch-all binding that encodes the key and writes it to the PTY. Clicks already resolve through node keymaps (STATUS, owner decisions).
  - Today the keys plugin falls back only to `<printing-char>` (`plugins/keys/plugin.ss:208-224`). A terminal needs an "any other key" fallback, like Emacs's `[t]` default binding.
  - That fallback is a general keys-contract feature, not something shaped for the terminal; still, it is a contract change to brief.
- **Which keys Tuna keeps.** Follow weevil's recommendation and eat/vterm's semi-char mode (`terminal-design.md:325-342`): send everything to the child except a small reserved set, plus a char mode that sends everything and has one escape key.
  - The reserved set needs owner input. Weevil already asked this question (`terminal-design.md:434-439`).
  - A reasonable start: `C-x` and `M-x` as editor prefixes, `C-g`, the window and tab keys of the layout plugin, and the browser paste shortcut.
  - `C-c` must reach the shell, so it cannot also be the user's prefix in char mode.
- **Mouse and wheel** go through Tuna's `pointer-event` and `scroll-event`, with the three-way wheel rule (`app.ss:208-222`; `scrolling-research.md:3-12`). Scroll reports are special events (`plugins/keys/contract.ss:51-60`), which suits "real-time intent, drop stale samples".

### Where the PTY reader runs

- **Not as a source.** A Tuna source polls on a timer and compares readings (`tuna/lib/background.ss:186-199`), which is wrong for a byte stream.
- **Use a job that posts several results** (`tuna/lib/jobs.ss:125-132`; brief `2026-10-background-work.md:22-27`):
  - Its `run` blocks on the PTY port's `read-subu8vector`. Gambit ports wait without blocking the VM.
  - It posts byte chunks with `coalesce: 'queue`, so no bytes are lost.
  - It may batch, for example by posting whatever has arrived up to 64 KB.
- **Parse in `apply` on the editor thread.** `apply` calls `terminal-write!`, drains the queued effects (PTY replies written back, title, bell, OSC 52 clipboard, working directory), and marks the terminal changed.
  - Why not parse on the job thread: Tuna's jobs are Gambit threads in one operating-system thread, and native calls block the whole VM (STATUS: "Parakeet calls block the whole Gerbil VM"). So parsing elsewhere buys no parallelism.
  - Parsing on the editor thread also keeps the terminal handle owned by one thread, matching "only the editor thread changes editor state". It still has to obey the gate rule: handlers only queue.
  - VT parsing is cheap (8 KB in about 10 µs).
- **Frame copy.** One frame copy per redisplay, not per chunk, gives weevil's "emulator is the coalescer" for free.
- **Child exit and shutdown.** The job posts the exit status. Turning the plugin off cancels the job and must kill the whole PTY session (go-web-terminal's session scan, `terminal_job_linux.go:557-613`), not just the leader.

### Library vs plugin

| Piece | Where | Why |
| --- | --- | --- |
| libghostty FFI | `gerbil-libghostty`, an external package dependency | Already a complete binding; needs a first commit and a packaging story. |
| Starting programs on a PTY, resize, write, read, exit status, killing the session | Tuna's planned **process library** (`docs/roadmap.md:71`), in `tuna/lib/` | Search, git, language servers and formatters need the non-PTY half too. Bring the C helper from `examples/browser-terminal/native/pty-process.c` (Gambit's PTY option is unreliable, `README.md:28`) and go-web-terminal's session cleanup. |
| Browser `code` → physical key, cells → run lists, wheel routing rule | Plugin-private files of `plugins/terminal/` | Only the terminal uses them. Promote them only when a second user appears (Tuna `AGENTS.md`, "Prefer deleting an abstraction"). |
| Terminal node kind, row rendering, `tokens.css`/`rules.css`, input modes and keymaps, OSC 52 → Tuna clipboard, title/working directory → buffer name and `default-directory`, the reader job | `plugins/terminal/plugin.ss` | Feature code; the kernel does not grow (ADR 12). |
| Catch-all key binding | Keys contract and plugin | A general keymap feature that Emacs also has. |
| Saving terminals across restarts | Terminal plugin through a session slot (`plugins/session/contract.ss:13-30`) | Slots hold plain data. `terminal->snapshot-bytes` yields a `u8vector`, which needs a byte-safe encoding or a separate file in `state-directory`. Running processes cannot be restored: a restored terminal shows its last screen and scrollback with no live child unless the user restarts one. Nobody has built this yet. |

## Residual risks

- The binding has no commits and no packaging path. It needs Zig 0.16.0 and a rebuild if moved. Only Linux x86-64 is validated.
- Full-frame copying may dominate on large grids, and the dirty-rows API is not designed.
- The callback gate's head-of-line blocking matters if a handler ever does real work.
- A native crash in libghostty takes down the whole editor; no isolation exists (weevil flagged the same thing).
- The owner must decide truecolor styling, the reserved keys, and whether to add key-up and lock-key facts to Tuna's input.

## 7. Binding gaps: spot-checks and what an interactive Tuna terminal needs

The owner supplied another agent's audit: 73 of 208 header functions in the pinned headers are never called by gerbil-libghostty. I did not redo it. I checked three of its claims against `ghostty.ss`, `private/ffi.ss`, `native/*.h` and the headers in `gerbil-libghostty/.build/ghostty-prefix/include/ghostty/vt/`.

### Spot-checks

| Claim | Result | Evidence |
| --- | --- | --- |
| `ghostty_render_state_row_iterator_next_dirty` is unused, so every render copies the whole frame | **Confirmed** | Declared at `vt/render.h:838`; no call in the binding's sources. `ghostty.md:99`: "The frame always copies the complete grid and pixels, even when dirty state is `clean`". |
| `ghostty_terminal_scroll_viewport` and `ghostty_terminal_paste` are unused | **Confirmed** | Declared at `vt/terminal.h:2851` and documented at `vt/terminal.h:1045`; no call in the binding. The browser demo's "viewport scroll" branch returns a symbol and moves nothing (`examples/browser-terminal/app.ss:211`, `:222`). |
| `ghostty_osc_set` is deliberately excluded | **Confirmed, but it is the wrong function for a terminal** (see below) | `ghostty_osc_set` configures only the standalone OSC parser (`vt/osc.h:60-85`, `:320`). |

### Custom OSCs (for example Rune's OSC 7501)

- **`ghostty_osc_set` does not block them.** It applies only to a standalone `GhosttyOscParser` that you feed by hand (`vt/osc.h:60-85`). Output from a program running in the terminal goes through the terminal's own parser.
- **The terminal reports unknown OSCs elsewhere.** It reports any APC or OSC it does not implement through the terminal option `GHOSTTY_TERMINAL_OPT_UNKNOWN_SEQUENCE`. The tag says APC or OSC, and the OSC value holds `content` (for example `7501;…`), a `truncated` flag and the `terminator` to answer with (`vt/terminal.h:103`, `:138-193`, `:534-537`, `:576-597`). APC (Application Program Command) is another escape-sequence family.
- **The real blocker is the binding's filter.** It installs that callback but drops everything except APC: `if (!request || request->tag != GHOSTTY_TERMINAL_UNKNOWN_SEQUENCE_APC) return;` (`private/ffi.ss:104`). It then always builds `(unknown-sequence 'apc …)` (`ghostty.ss:1048-1051`, `private/ffi.ss:382`). It was filtered on purpose, to match the Racket reference (`ghostty.md:64`). So **today a Tuna terminal cannot see OSC 7501.**
- **Cost of reversing.** It is small and local to the binding:
  1. Remove the tag filter.
  2. Add accessors for the tag, the OSC terminator and `value.osc.content` / `.truncated`, next to the existing APC ones.
  3. Return `(unknown-sequence 'osc content truncated?)`, and add the terminator so a reply can end the same way.
  4. Add one header-layout check (`native/core-test.c:605` already checks the APC enum), plus tests for split and truncated OSCs.

  Roughly 20–40 lines of C and Scheme, plus tests. Runtime cost is one gated callback per unknown sequence, and only when `terminal-set-unknown-max-bytes!` is above zero (the default zero captures nothing, `ghostty.md:66`). Hooking `ghostty_osc_set` is not needed for this. Reversing the Racket-parity choice is an owner call, but it costs little.
- **In Tuna**, the terminal plugin would turn each unknown OSC into a hook or a per-number handler table, run on the editor thread after the write returns (the gate rule). Shell integration (OSC 133 prompts, OSC 7 working directory) is already handled natively.

### Do dirty rows and the allocation rate matter for the per-row memo renderer?

**Yes, for the server cost of each frame. Not for correctness.**

- **`memo` reuses HTML, not the copy.** With the full copy, every frame still allocates every cell of the grid (about 1.5 MB at 80×24 and about 6 MB at 160×48, `PARITY.md:252-259`) before the plugin can compare rows.
- **What a flood costs.** At a paced 30 frames a second, a 160×48 terminal under constant output would allocate about 180 MB a second and spend about 140 ms a second copying. That load lands on the one OS thread that also runs the editor and every other job, because Gambit threads are green. A blinking cursor or a one-line `htop` refresh pays the full price too.
- **Idle cost is zero.** No output means no frame.
- **With `next_dirty`,** the plugin would copy only rows Ghostty marks dirty. Those are exactly the rows whose per-row source it would stamp, so Ghostty's dirtiness and ADR 17's "stamp only what changed" line up. The `equal?` cutoff on run lists then becomes a cheap safety net instead of the main filter.
- **Ranking: needed before large or busy terminals are pleasant, not for a first slice.** A first slice can copy the full frame, convert to run lists and compare by value, paced at 16–33 ms. Add a dirty-row copy (iterate with `next_dirty`, copy only those rows, acknowledge dirtiness) as the binding's first new API. Shape it as "rows that changed since the last copy", returning detached rows; this avoids the borrowed views `PARITY.md:37` rules out.
- Building run lists directly in C from cells, instead of materialising a Scheme record per cell, would cut allocation further. That is a second step.

### Is the global callback lock a problem with one PTY reader per terminal off-thread?

**No, if the reader only reads bytes. Yes, if each reader also parses.**

- **What the lock covers.** It serialises only "callback-capable" calls: writes and anything that can raise effects (`ghostty.md:15`, `:19-25`). Grid, selection, mode queries, encoders and parsers do not take it, or take only the terminal's own mutex.
- **With the recommended design (section 6),** each terminal's job blocks on its PTY port, which uses no native code, and posts bytes. The editor thread then calls `terminal-write!`. All gated calls happen on one thread, so the lock is never contended. Handlers only queue, so nothing waits inside a callback.
- **If each reader called `terminal-write!` on its own thread,** the lock still keeps things correct. The cost is head-of-line blocking: a slow handler on one terminal stalls every terminal and the editor's key encoding for terminals.
  - It buys no speed, because all Gambit threads share one OS thread.
  - It also breaks the rule that callbacks must not wait on another gated thread if a handler ever touches editor state that is waiting on the editor thread.
- **Conclusion:** the lock is not a problem for Tuna, provided parsing stays on the editor thread.

### What an interactive Tuna terminal needs from the binding, ranked

| Rank | Need | In the binding today? |
| --- | --- | --- |
| 1 | Write, resize, full render frame, key/mouse encoders, paste encoding, modes, PTY-reply/title/working-directory/bell/OSC 52 effects | Yes |
| 2 | **Scrollback viewing**: reading styled rows by screen position without moving the viewport, plus the total-rows, scrollback-rows and scrollbar reads (`scroll_viewport` is not needed under Tuna's model; see below) | **No** (confirmed). Without them, scrollback cannot be drawn at all. |
| 3 | **Scrollback limit and palette/colour options** (the audit's 25 missing terminal options): a theme's default foreground/background/palette, scrollback size | **No**, per the audit. Colours could instead be applied by Tuna's CSS from palette indices, but resolved colours and OSC 4/10/11 queries need the options. |
| 4 | **Dirty-row render copy** (`next_dirty`) | **No**, confirmed. Performance, see above. |
| 5 | **Unknown OSC to the host** (custom OSCs such as OSC 7501) | **No**, confirmed: filtered to APC at `private/ffi.ss:104`. Small fix. |
| 6 | Direct reads: cursor, size, mouse-tracking state, Kitty keyboard flags | Mostly available indirectly (frame cursor, `terminal-mode-enabled?`). Direct reads are convenient, not blocking. |
| 7 | Selection gestures (`ghostty_selection_gesture_*`) and search (`ghostty_search_*`) | **No**, per the audit. Manual selection calls exist (`ghostty.md:80-93`), so Tuna can drive word and line selection itself. Search can wait for a find-in-terminal command. |
| 8 | `ghostty_terminal_paste` (paste as an event to programs that ask for it) | **No**, confirmed. `paste-encode` covers ordinary and bracketed paste. |
| 9 | Compression (`ghostty_terminal_compress`, `compression_activity`), memory use | **No**, per the audit. Matters for many long-lived terminals with big scrollback; later. |
| — | `ghostty_sys_set` (process-global hooks) | Excluded, and should stay excluded (one process, many plugins). |

### Scrolling a terminal like any Tuna view (rows as items, ADR 15)

In Tuna, every row (scrollback plus the active screen) is an item. The browser scrolls natively, and each tab draws only the items near what it shows. Here is what the binding offers for that.

- **Reading any row without moving libghostty's viewport.**
  - *Natively, yes, but one cell at a time.* `ghostty_terminal_grid_ref` resolves a point in `SCREEN` (scrollback plus active) or `HISTORY` coordinates (`vt/point.h:49-58`, `vt/terminal.h:2987`). Cell, row, grapheme, style and hyperlink are then read from it (`vt/grid_ref.h:124-203`). None of this touches the viewport.
  - The header warns: "not meant to be used as the core of a render loop … Use the render state API for that" (`vt/grid_ref.h:28-30`).
  - The formatter can also be limited to a selection range (`vt/formatter.h:116-118`). I did not check whether it can produce styled output for that range.
  - *In the binding, effectively no.* It uses untracked refs only inside selection calls (`native/grid-selection.h:219-246`). It exposes tracked refs, whose snapshot returns **one cell** (`ghostty.md:72-76`), and `terminal-selection->plain-text` for a range (plain text, no styles). It has no call that reads styled rows by screen position.
- **The render state reads only the viewport, and there is one viewport per terminal.**
  - `terminal-render-snapshot` copies the viewport only.
  - `ghostty_terminal_scroll_viewport` (unbound) moves that single shared viewport. Serving several tabs at different scroll positions would mean scroll, copy and scroll back for each tab. That mutates shared state while drawing and is wrong under ADR 17.
  - **Needed binding call:** copy screen rows `[y0, y1)` as detached render rows without touching the viewport. Implement it in C over grid refs or the row and cell API, returning the same `render-row` records as frames. Each tab's view asks for its own window of rows. The binding also needs the unbound reads `GHOSTTY_TERMINAL_DATA_TOTAL_ROWS`, `SCROLLBACK_ROWS` and `SCROLLBAR` (`vt/terminal.h:2235`, `:2284`, `:2291`) for spacer sizes, plus the scrollback limit options (`:2485`, `:2496`).
  - The "not for render loops" warning matters less here: Tuna copies only the rows near each tab's view, and only rows whose content changed. Scrollback rows above the active screen rarely change.
- **Stable row identity.**
  - **Screen-coordinate y is not stable:**
    - trimming at the top shifts every row's y;
    - reflow on resize changes how many rows there are and how lines wrap;
    - a full reset clears the screen and scrollback (`vt/terminal.h:1305`).
  - **CSI 3J (erase scrollback)** is not documented in the headers. Its effect on refs needs a test.
  - **Tracked refs follow a cell** through scrolling, pruning and reflow, until the grid is "reset, pruned, or otherwise discarded". Then they report no value (`vt/grid_ref.h:47-58`). The binding's tests confirm pruning clears stale pins (`PARITY.md:15`).
  - A tracked ref per row would cost an update on every terminal change. The header says untracked refs avoid that ongoing cost (`vt/grid_ref.h:40-42`), which implies tracked ones do not. Thousands of them are the wrong tool.
  - **Suggested identity:** an absolute row number, the count of rows ever trimmed plus the screen y. The trimmed count is not exposed. It can be derived from one tracked ref anchored at the oldest row, by watching its screen y and its loss of value.
  - Reflow and scrollback clearing should start a new **generation** in which all row keys renumber. Each tab's scroll position is then re-anchored by a tracked ref on its top visible cell (ADR 15's "item plus offset"), so the view stays on the same text after a resize.
  - Row content is still compared by value (ADR 17), so renumbering after reflow redraws only rows whose run lists actually differ.
- **The alternate screen (vim, less, htop).**
  - Frames say which screen is active: `render-snapshot-screen` is `primary` or `alternate` (`ghostty.md:103`); natively it is `GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN` (`vt/terminal.h:2203`).
  - Snapshots carry separate primary and alternate histories; alternate may be absent (`snapshot-history-alternate-rows`).
  - Tracked refs stay with the screen they were made on (`vt/grid_ref.h:60-66`).
  - So while the alternate screen is active, the view should show a fixed grid of active rows with no scrollback items. The wheel goes to the program by the three-way rule. The primary scrollback, and each tab's anchor in it, waits untouched until the program exits (weevil reached the same design, `terminal-design.md:316-319`).

**Order of binding work for Tuna (revised):**
1. Copying screen rows by range without moving the viewport, plus the total-rows, scrollback-rows and scrollbar reads. This is the backbone of Tuna-style scrolling, and it makes `scroll_viewport` unnecessary.
2. The scrollback-limit and colour options.
3. Unknown OSC.
4. Dirty rows for the active screen.
5. Tests of CSI 3J against tracked refs.

Each is a bounded addition to an uncommitted repository, so the binding should get its first commit before any of it.
