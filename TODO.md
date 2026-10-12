# TODO

## Report or fix upstream (Gerbil / Gambit)

- [ ] **`gxc -O` hangs on an empty self-loop.** Compiling a module containing `(let lp () (lp))` with the optimizer never finishes; without `-O` it compiles. Found in stage 1 on Gerbil v0.19-dev-63 / Gambit v4.9.8; reproducible with a one-line module. Tuna works around it by giving such loops a body.
- [ ] **`thread-interrupt!` blocks its caller** until the target thread runs the interrupt, and raises `abandoned-mutex-exception` in the caller when the interrupt escapes. Check whether this is intended Gambit behavior and documented; if so, note it for Gerbil users, otherwise report it. Tuna interrupts from a helper thread.
- [ ] **`append-map` in `:std/list/list` reverses each sublist.** `(append-map (lambda (x) [x (* 10 x)]) [1 2 3])` returns `(10 1 20 2 30 3)` on Gerbil v0.19-dev-63: the final fold conses each result's elements onto the accumulator. Found in stage 4. Tuna's plain-text renderer avoids it; `buffer-texts` (order of several text nodes) and the kernel's dependency closures (order irrelevant) still use it.

## Tuna

- [ ] **Jobs that post several results** (carry-over from stage 3). A job's `run` returns one result. Posting partial results (for example a highlighter coloring a large text in chunks) needs a way for `run` to post through the job's validity check without finishing; deferred until a job needs it.
- [ ] **`displayln` with a port argument.** Gerbil's `displayln` displays all its arguments to the current output port, so `(displayln text (current-error-port))` prints the port object to standard output. Stage 1–3 code does this in `report-failure!` (`tuna/kernel/plugins.ss`), the redisplay failure report (`tuna/kernel/loop.ss`), and `usage` (`tuna/main.ss`); stage 4 code writes to the error port directly.
- [ ] **Autosave runs on the baton.** Each changed text is written synchronously while idle. Texts are persistent, so a large text could be written from a job over a snapshot instead.
- [ ] **No `fsync` before the atomic rename** of session and autosave files: a crash of the machine (not of Tuna) shortly after a save could leave an empty file on some file systems. Gambit has no portable `fsync`.

- [ ] **Session restore order is implicit.** Slots restore in the order plugins registered them; `main.ss` activates autosave before the window manager so buffers exist before windows refer to them. Make restore order explicit (dependencies between slots) before more stateful plugins arrive.
- [ ] **Window contract is partial.** ADR 11's split, delete, neighbor, swap, `display-buffer`, window configurations, parameters and dedicated windows are not built; due with the real window manager.
