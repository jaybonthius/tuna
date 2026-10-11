# Lane 1: Command loop, input, keymaps, minibuffer and completion

Scope: ADRs 1–7 and `docs/overview.md` in `/home/jay/Code/workbench-gerbil/tuna`, audited against Emacs at `/home/jay/Code/emacs` (commit 541f693c; Elisp manual in `doc/lispref/`), installed ELPA packages under `/home/jay/.config/emacs/var/elpaca/sources/`, and Gerbil v0.19-dev-63 / Gambit 4.9.8 (`/opt/gerbil/bin/gxi`).

Evidence labels: **[src]** Emacs/Gerbil source or manual; **[exp]** I ran it in `gxi` this session (throwaway scripts in `/tmp`, no repo files touched); **[inf]** my inference. The repo contains no Tuna runtime yet: `tuna/main.ss` only prints a version, and `frontend/tuna-keyboard.ts` is the only input code. Everything about ADR 3 is therefore design-level.

Shallow areas (said up front): mouse events/drag/context menus/menu bar/tool bar, quail/text composition internals, and completion styles/metadata. These get inventory rows, not mechanism-level study.

## Summary

1. **C-g cannot interrupt a long command as ADR 3 is written (corner risk).** The loop dequeues, resolves keys, and "lends the baton to one command at a time"; the Consequences section says long computation "delays subsequent commands". A queued C-g sits behind the very command it should stop. Emacs avoids this by detecting the quit char when the event is *stored*, not when it is read (`keyboard.c:3794-3842`). The needed primitive exists in Gambit and works (see Corner risk 1), with one quirk I measured.
2. **Several simultaneously suspended commands plus "restore on exit" dynamic state is unsound (corner risk).** ADR 3 says "several may be suspended" and does not say they resume LIFO. Any `let`-style temporary override of command-loop state (inhibit-quit, prefix arg, overriding maps) restores wrongly if resumes interleave. Emacs recursive edits are strictly nested, so this never arises there.
3. **Command-loop state has no home in the ADRs.** `this-command`, `last-command`, `prefix-arg`, pending key prefix, macro state, transient maps: ADR 4 says scoped values are "not dynamic variables" and lists only buffer/window/frame/minibuffer objects. In Emacs `this-command` is a plain global and `last-command`/`real-last-command`/`last-repeatable-command`/`prefix-arg`/`overriding-terminal-local-map`/`input-decode-map`/`local-function-key-map` are per-terminal `KBOARD` slots. Tuna needs an explicit input-session object (name proposed: `InputSession`). With all browser tabs mirroring one frame (ADR 7), a key typed in tab B can complete a `C-x` started in tab A unless events carry a client id.
4. **Browser-reserved keys (corner risk to product viability).** Core Emacs keys `C-n`, `C-w`, `C-t` (and `C-S-t`, `C-Tab`, `M-Left`) are browser-reserved in Chrome/Safari and cannot be rescued with `preventDefault()`. Only fullscreen + Keyboard Lock (Chromium, permission-gated) or a native shell captures them. ADR 7's "browser acts like a terminal" does not address this.
5. **Keyboard macros fit, if replay is an input *source* feeding the loop, not a nested loop.** Emacs's `execute-kbd-macro` runs a nested command loop inside the calling command (`macros.c:276-380`); that shape does not map onto ADR 3's loop-owned dispatch. A loop-owned macro source works better than Emacs for minibuffer prompts, but needs rules for async job results and macro end/abort (Corner/Later rows 41–47).
6. **Receipts that "walk backwards" restoring prior values break for non-commutative state like keymap slots (corner risk, small).** Plugin A binds `C-c k`; plugin B overrides it; A deactivates first; restoring A's "previous value" erases B's binding. Fix: owner-tagged keymap layers where the inverse is "remove my entry".
7. **Mouse events need a render epoch (small corner risk).** ADR 7 maps clicks "back to nodes and positions" but the whole frame is re-morphed on every redisplay, and the viewport is server-sliced. A click computed against frame N applied against state N+3 selects the wrong text. Events need a frame/revision stamp now (cheap).
8. **Mid-command redisplay is unspecified.** `sit-for`, `redisplay`, progress `message`: Emacs's magit uses `sit-for` in five files. ADR 3 renders only after a command completes or suspends. Needs one explicit "yield to render" suspension point (a *later* item, but name it).
9. **Best improvements over Emacs:** (a) true preemptible quit with per-thread `inhibit-quit`; (b) built-in pending-prefix inspection (which-key without idle-timer hacks) because the loop owns key resolution; (c) owner-tagged keymap layers and focus-node keymap chains; (d) completion tables that declare themselves pure and run as jobs on snapshots; (e) timers registered through plugin contexts (cancelled on deactivation); (f) deterministic macro replay (no async interleaving).
10. **Mostly covered/fits:** direct-style `read-string`/`completing-read`/`y-or-n-p`, the minibuffer as a buffer with its own keymap, recursive minibuffers, `recursive-edit`, hooks, advice on commands, `unread-command-events`-style re-injection, repeat-mode, set-transient-map. All reduce to "an input-target stack in the loop plus suspension", which ADR 3 already has in embryo.

## Inventory

Status values: covered / later / corner-risk / divergence. "ADR" means the decision constraining Tuna today; "none" means no ADR speaks to it. Emacs references use `file:line` in `/home/jay/Code/emacs` (abbreviated) or manual node names.

### A. Commands and interactive specs

| # | Capability | Emacs mechanism / equivalent | Relied on by | Tuna today (ADR) | Status | Notes |
|---|---|---|---|---|---|---|
| 1 | Define a command | `defun` + `(interactive ...)`; `commandp` | everything | `defcommand` in `:tuna/prelude`, lowers to registration (1, 2) | covered | Overview example `(defcommand (forward-char (count 1)) ...)` has no interactive spec; see row 2. |
| 2 | Interactive argument codes (`p P r s n f b e * @ ^ <` …) | `commands.texi` node "Interactive Codes" (:341); `callint.c:256` `call-interactively` | `M-x`, keymap dispatch, macros, `repeat`, `describe-function` | none; example shows defaults only | later | Needs a per-parameter *argument source* annotation (raw prefix, numeric prefix, region, prompt, event, buffer-name…). Region (`r`) and read-only (`*`) checks are command-loop semantics, not syntax. Propose structured descriptors (divergence D3), with an `(interactive "p")` compatibility reader for ported code. |
| 3 | `interactive-form`, `commandp`, command introspection | `interactive-form`, `commandp` (accepts byte-code/closures) | `describe-function`, `M-x` filtering, `keymap-set` validation, embark | none | later | Command objects should be records (name, doc, arg-spec, modes, category, repeat-map) held in a registry keyed by name. |
| 4 | Bind keys to command *names*, not closures | keymap entries are symbols; `Ffset` redirects | remap, advice-on-command, `where-is`, reload | Overview: `(define-key global-map "C-f" forward-char)` (bare identifier) (1) | corner-risk (low) | If `forward-char` evaluates to a procedure, redefining/advising/reloading (ADR 2 "Reload", "Advice wraps commands") cannot affect existing bindings, and `where-is`/`describe-key`/remap/custom.ss serialization lose names. State that keymaps store command *names* (or stable command objects) resolved at dispatch. |
| 5 | `call-interactively`, `command-execute`, `funcall-interactively`, `called-interactively-p` | `callint.c:256`; `keyboard.c:1545` calls `command-execute` | `M-x`, macros, `repeat`, transient | ADR 3: "each interactive command runs in its own Gambit thread" | covered | Only the *top-level* dispatch needs a new thread. `call-interactively` from inside a command (e.g. `execute-extended-command`, `keyboard-escape-quit`) should be a plain nested call on the same thread/baton. State that rule. Measured: Gambit thread spawn+join ≈1 µs each (interpreted `gxi`) [exp], so per-command threads are not a latency concern. |
| 6 | `command-modes`, mode-restricted `M-x` | `commands.texi:647` "Command Modes"; `read-extended-command-predicate` (`simple.el:2251`) | `M-x` completion, `execute-extended-command-for-buffer` | none | later | Command record `modes` field. |
| 7 | `execute-extended-command` + completion over commands | `simple.el:2601` | M-x everywhere | none | later | Sets `this-command` to the invoked function explicitly (`simple.el:2636-2645`) because the minibuffer clobbers it; see Emacs equivalence notes. |
| 8 | Command remapping | `[remap cmd]` in keymaps; `command-remapping`; `keyboard.c:1495` (`read_key_sequence_remapped`) | modes that replace `kill-line`, `newline` etc. | none | later | Natural once keymaps hold names (row 4). Remap at dispatch, record `this-original-command`. |
| 9 | Advice on commands | `advice-add` | many packages | ADR 2 (advice wraps commands) | covered | Advice wraps the registry entry; deactivation reverts it. |
| 10 | Command history, `repeat-complex-command`, `command-history` | `commands.texi` "Command History" | `C-x ESC ESC` | none | later | Needs a record of interactive invocations (command + resolved args); pairs with D3. |
| 11 | Errors in commands: report, continue | `cmd_error` (`keyboard.c:964`), `command-error-function` | all | ADR 3 "Errors", ADR 4 "No rollback" | covered | Also: error during macro replay must abort the remaining macro (`keyboard.c:977-992`). Row 44. |
| 12 | `debug-on-error` / `debug-on-quit` | debugger via `signal_or_quit` | development | none | later | Command thread + Gambit continuations permit capture-before-unwind [inf]. |

### B. Prefix arguments and command chaining

| # | Capability | Emacs mechanism | Relied on by | Tuna today | Status | Notes |
|---|---|---|---|---|---|---|
| 13 | `C-u`, `universal-argument`, `digit-argument`, `negative-argument` | `simple.el:5455-5511`; commands read keys through the loop as ordinary commands that set `prefix-arg` | all `"p"`/`"P"` commands | none | later | These are ordinary commands that set loop state; require an input-session slot `prefix-arg` that the loop *carries to the next command* (`keyboard.c:1322`: cleared at loop entry only; set by commands). |
| 14 | `prefix-arg` vs `current-prefix-arg` vs `last-prefix-arg` | `prefix-arg` = argument for the *next* command (KBOARD slot); `current-prefix-arg` = for the *current* command (`callint.c:878`); `last_prefix_arg` set after each command (`keyboard.c:1573`) | magit (29 files refer to `current-prefix-arg`), hydra, consult, embark | none | later | Must be three distinct slots in `InputSession`. Port note: `current-prefix-arg` is routinely `let`-bound by callers (e.g. `(let ((current-prefix-arg '(4))) (call-interactively …))`), so it needs dynamic-style binding (corner risk 3). |
| 15 | `this-command` | global `Vthis_command` (`keyboard.c:13808`), set before `pre-command-hook` (`:1506`), settable by commands | undo, kill, `cycle-spacing`, vertico, magit, meow, hel | none | corner-risk | No ADR gives it a home. Propose `InputSession` field with accessor and `with-this-command`. |
| 16 | `last-command`, `real-last-command`, `last-repeatable-command` | per-KBOARD slots (`keyboard.c:13781-13802`); set after post-command-hook (`:1579-1582`); `last-repeatable-command` only set if `last-command-event` is not a cons | consecutive-kill append (`kill-region`, `simple.el:5886`), `undo`, `next-line` goal column (`simple.el:8055-8175`), `repeat` | none | corner-risk | Same home as row 15. Per-session, not global, once multi-client exists (Open question 1). |
| 17 | Command chaining (consecutive kills append, repeated `C-/` continues undo) | `last-command` compare in the command | kill ring, undo, isearch, `cycle-spacing` | none | covered | Works as soon as rows 15–16 exist. Subtlety: with suspension (rows 28–32), the minibuffer's inner commands overwrite `this-command` before the outer command resumes. Emacs fixed `M-x` specially (`simple.el:2636-2645`). Tuna can do better: per-activation command context (D6). |
| 18 | `pre-command-hook` / `post-command-hook` | `safe_run_hooks` around `command-execute` (`keyboard.c:1507,1572`); hook errors *delete the function* from the hook (`:1908-1960`) | transient (`transient.el:2831`), repeat-mode, corfu, vertico, meow, hel, magit | ADR 2 (ordered named hooks, context-registered), ADR 3 ("hooks schedule, they do not compute") | covered | Needs a spec for *suspension*: post-command-hook should run when the command *completes*, not when it suspends; inner minibuffer commands run their own pairs (Emacs behavior). Divergence: failed hook function is logged and kept (or disabled with a receipt note), not silently removed; named callbacks make this safe. |
| 19 | Command-loop lifecycle stages in C | undo boundary, point adjustment (`disable-point-adjustment`), `deactivate-mark`/`activate-mark-hook`, `select-active-regions`, echo clearing, `last-command` update (`keyboard.c:1318-1650`) | transient-mark-mode, intangible/invisible text | none | later | Make the loop a pipeline of named plugin-extensible stages; do not hard-code. |

### C. Keymaps, key lookup, translation

| # | Capability | Emacs mechanism | Relied on by | Tuna today | Status | Notes |
|---|---|---|---|---|---|---|
| 20 | Global map, buffer-local map, minor-mode maps | `current_active_maps` (`keymap.c:1650-1740`); `minor-mode-map-alist`, `minor-mode-overriding-map-alist` (`keymap.c:3375`) | every mode | ADR 3: "resolves keys through the active keymaps"; ADR 6: buffer owns "active modes" | later | Precedence order is not specified anywhere. Must be: keymap-providers list computed per lookup. Tuna `buffer.modes` → keymaps is a clean source. |
| 21 | `overriding-terminal-local-map`, `overriding-local-map` | `keymap.c:1676-1685`; used by transient, hydra (`hydra.el:124`), `set-transient-map`, hel (`hel-core.el:497-539`) | transient, hydra, repeat, isearch | none | later | Belongs in `InputSession` (terminal-local). Keymap stack with push/pop (`internal-push-keymap`). |
| 22 | `emulation-mode-map-alists` | consulted before minor-mode maps (`keymap.c:1536`) | Meow (`meow-core.el:167-171`), hel (`hel-core.el:65`), Evil | none | later | A provider layer *above* minor modes, per-buffer. Simply an ordered list of keymap providers; no architectural block. |
| 23 | `keymap`/`local-map` text and overlay properties | `get_local_map` at point (`keymap.c:1685-1700`) | text-button, org links, magit sections, completion UI | ADR 6: text node has "text properties"; overlays never mentioned | later | Lookup goes via `TextStore` properties at point; overlays need a design in another lane. Divergence D2b: also allow keymaps as *node attributes* with lookup up the focus node's ancestor chain (DOM-style bubbling). |
| 24 | Prefix keys, sparse/full keymaps, parent inheritance | keymap lists, `set-keymap-parent`, `make-composed-keymap` | all | ADR 4: keymaps are `defclass` objects; ADR 1: `defkeymap` | later | Tuna keymap object = (entries, parent(s)); `make-composed-keymap` becomes multiple parents. Keep `keymap-lookup`, `map-keymap`, `copy-keymap`. Packages that treat keymaps as lists (`(keymap ...)` surgery) cannot port mechanically; rare. |
| 25 | `define-keymap`, `keymap-set`, `key-valid-p`, key description syntax | `keymap.el:44,328,594`; `kbd` (`subr.el:1258`) | modern packages | ADR 1: `define-key`, `defkeymap`; overview: `(define-key global-map "C-f" …)` | later | Near-miss: in Emacs `(define-key map "C-f" …)` treats the string as the characters `C`,`-`,`f`; the `"C-f"` syntax belongs to `keymap-set` (see Equivalence notes). Recommend only one key-string syntax (the `keymap-set` one) and name the function accordingly. |
| 26 | Owner-tagged keymap bindings, reversible | n/a (Emacs mutates) | plugin deactivation, ADR 2 | ADR 2 receipt: "runs the receipt's inverses in reverse order" | corner-risk (small) | Overwrite order breaks restore-previous inverses. See Corner risk 4 and D2. |
| 27 | Menu items with filters (`menu-item`), menu bar, tool bar, context menus | `keymaps.texi` "Menu Keymaps", "Menu Bar", "Tool Bar" | `easy-menu`, every mode, `context-menu-mode` | ADR 7: HTML renderer, mouse "later" | later (shallow) | Menus are keymaps rendered as HTML by the renderer service; browser native `contextmenu` must be suppressed and replaced. Keyboard menu access (`F10`, `tmm`) needs the same keymap data. |
| 28 | Pending-prefix inspection (which-key, `describe-prefix-bindings`, `C-h` after prefix) | `which-key.el` polls `this-single-command-keys` on an idle timer; `prefix-help-command` | which-key, embark, discoverability | ADR 3: loop resolves keys | divergence | The loop *is* the key resolver, so it can expose `(pending-bindings)` synchronously and render a pending-prefix panel as part of the frame. See D8. Packages using `this-command-keys` + `key-binding` still port. |
| 29 | Key translation: `input-decode-map`, `local-function-key-map`, `key-translation-map`, `function-key-map` | KBOARD slots (`keyboard.c:14155,14184`), `key-translation-map` (`:14209`) | ESC→Meta, `<f1>`→`C-h`, `C-x 8`, kkp, `ctl-x-map` tricks | ADR 7: events carry `key`/`code`/modifiers; no translation stage defined | later | Three translation layers must be explicit stages between raw browser event and key lookup. Browser `Alt` as Meta, `Escape` prefix (`ESC x` ≡ `M-x`), macOS Option-composed characters (use `code`, not `key`), `AltGr`. |
| 30 | Event representation, `last-input-event`, `last-command-event`, `recent-keys`, `this-command-keys`, `event-modifiers`, `listify-key-sequence` | `commands.texi` "Input Events" | `self-insert-command`, macros, `describe-key`, `view-lossage` | ADR 7 JSON `keydown` event (version 1, `key`, `code`, modifiers) | later | Schema has no timestamp, client id, sequence number or frame epoch (corner risk 6/7). Define a Scheme event record and a canonical key string ↔ event bijection. |
| 31 | Key-event delivery vs browser reserved keys | n/a (terminal owns C-g, C-s/C-q flow control; Emacs can disable) | `C-n`, `C-w`, `C-t`, `C-S-n`, `C-Tab`, `M-Left` | ADR 7 plugin calls `preventDefault` | corner-risk | See Corner risk 5. |

### D. Event reading inside commands, suspension, recursive edit

| # | Capability | Emacs mechanism | Relied on by | Tuna today | Status | Notes |
|---|---|---|---|---|---|---|
| 32 | `read-event`, `read-char`, `read-key`, `read-key-sequence`, `read-char-choice` | `read_char` (`keyboard.c:2555`); `read-key` is Lisp over `read-key-sequence` (`subr.el:3603`) | avy, meow, embark, consult, magit, `y-or-n-p` | ADR 3: "A command that needs input … suspends" (examples: strings, minibuffer) | later | Same suspension mechanism. The loop needs *input targets* of two kinds: buffer-based (minibuffer) and raw-key readers (`read-key`, `y-or-n-p`, avy) that bypass keymaps but get key translation. Define a small target interface: `(accept! target event) → consumed? / pass-through`. |
| 33 | `read-key-sequence` semantics (decode+translate+keymap prefix collection inside a command) | `keyboard.c:10901` | embark (`read-key-sequence` use), meow | none | later | Loop already builds sequences for dispatch; expose same engine to commands. |
| 34 | `unread-command-events` (re-inject events) | `keyboard.c:13752`; used by cape, embark, flash, hel (`hel-scroll.el:142-153`), transient | "push the key back" pattern, `execute-kbd-macro`-like tricks | none | later | Loop-owned list consulted before the browser queue; `(t . ev)` "don't record" form for macros. Not thread-shared: commands call `(unread-event! ev)` on the loop via the baton. |
| 35 | `input-pending-p`, `discard-input`, `this-command-keys` | `keyboard.c:12076,12400,12244` | vertico, hel, which-key | ADR 3: loop owns queue | later | The queue must be inspectable by the baton holder (peek without consuming). The queue is a thread-safe structure shared with the HTTP threads; baton holder reads length/peek. |
| 36 | Direct-style suspension (`read-string`, `completing-read`, `y-or-n-p`) | `read_minibuf` → `recursive_edit_1` (`minibuf.c:912`) | thousands | ADR 3 "Commands" | covered | The core of ADR 3. Verified feasible: Gambit threads block on a channel and resume with state; no `call/cc` needed. |
| 37 | `recursive-edit`, `exit-recursive-edit`, `abort-recursive-edit`, `top-level` | `keyboard.c:781,1199,1234` | `query-replace`, `edebug`, `consult` flows, magit | ADR 3 (several may be suspended) | covered | Same suspension, with an "exit/abort token". Abort = resume the suspended thread with a quit exception so `dynamic-wind`/`unwind-protect` cleanups run (measured below). |
| 38 | Recursive minibuffers, `enable-recursive-minibuffers`, `minibuffer-depth` | `minibuf.c:56,637-646,2236` | embark, vertico, completion-in-minibuffer | ADR 3 | covered | Suspended stack = minibuffer depth. Enforce LIFO resume (corner risk 2). |
| 39 | Resuming "into a changed world" | Emacs recursive edits | all prompting commands | ADR 3 Consequences ("Commands re-read state after waiting") | covered | Same as Emacs; document that a buffer may be killed while a command is suspended on it (Emacs raises errors on dead buffers). |
| 40 | `sit-for`, `sleep-for`, `read-event` with timeout, `accept-process-output` | `subr.el:3852`, `dispnew.c:6894` | magit (5 files), meow, transient | ADR 3: suspension waits on input/answer; timers via context | later | Needs more suspension *reasons*: timeout, "any input arrives" (wake without consuming), job result, process output. `sit-for` also redisplays first (row 56). |
| 41 | Keyboard macro recording | `defining-kbd-macro`, `store_kbd_macro_char` at the event-read point; `start-kbd-macro`, kmacro ring (`kmacro.el`) | `F3/F4`, `C-x (`, `apply-macro-to-region-lines`, kmacro counter | none | later | Record at the loop's single *dequeue* chokepoint (after decode, before keymap) so keys consumed by minibuffer/read-key targets are captured exactly as in Emacs. |
| 42 | Keyboard macro replay: events to the loop | Emacs: `execute-kbd-macro` runs a nested `command_loop_2`, reading from the macro in `read_char` (`macros.c:276-380`; the comment at 346-358 admits pushing events into the queue is the "ideal") | `C-x e`, `call-last-kbd-macro`, `apply-macro-to-region-lines`, named macros | ADR 3 loop owns dispatch | later | **Verified shape:** make the macro an *input source* the loop reads before the browser queue, and make `execute-kbd-macro` a suspension that completes when the source is drained *and* the loop is at a command boundary. Minibuffer prompts during replay work (events route to the minibuffer target). Rules in Corner/Design notes below. |
| 43 | `executing-kbd-macro`, `defining-kbd-macro` checks | `macros.c:435`; used by meow (`meow-util.el:197-200`), hel (`hel-scroll.el:114`) | packages suppress `message`, animations, UI in macros | none | later | Loop-state flags on `InputSession`; part of pre-resolved event record (`replayed?`). |
| 44 | Macro errors abort the remaining macro; end-of-macro inside a prompt | `keyboard.c:977-992`; `macros.c:350-358` (end of macro handled at command boundary; in-prompt `read_char` continues from user) | all macro users | none | later | Specify: command error ⇒ clear macro source; macro end while a prompt is open ⇒ fall back to browser input. Mirrors Emacs. |
| 45 | Async completion events during macro replay | Emacs: process output/timers only processed while *waiting for real input* or in explicit waits | deterministic macros | ADR 3: user input before jobs | divergence-lite | Rule: while a macro source is active, defer job results/process output/timers except inside explicit waits (`sit-for`, `accept-process-output`, suspension on a job). Gives Emacs-like determinism. A command that suspends on a job during replay waits normally. |
| 46 | `kmacro` counter, ring, `kmacro-edit-macro`, `apply-macro-to-region-lines` | `kmacro.el` | power users | none | later | Plain plugin state; no architectural dependency. |
| 47 | Command-level (semantic) macros | n/a | robustness against context | none | divergence (optional) | Record resolved commands + args in addition to keys; optional replay mode immune to keymap changes. D4. |
| 48 | `repeat` (`C-x z`) and `repeat-mode` | `repeat.el:200`; `post-command-hook` + `set-transient-map` + `repeat-map` property | convenience maps | needs `last-repeatable-command`, transient maps | later | Requires rows 16, 21, 18. |
| 49 | `set-transient-map` (hydra, transient, repeat-mode) | `subr.el:7009`: pushes onto `overriding-terminal-local-map`, uses `pre-command-hook` to decide to pop | hydra, transient, meow, hel, corfu | none | later | Registered through a plugin context (hook + map push), popped on deactivate (ADR 2). The `pre-command-hook` decision-in-hook pattern needs "see the resolved command before it runs", which the loop provides. |

### E. Quitting

| # | Capability | Emacs mechanism | Relied on by | Tuna today | Status | Notes |
|---|---|---|---|---|---|---|
| 50 | C-g interrupts a running command | `quit_char` detected at event-store time (`keyboard.c:3794-3842`), `handle_interrupt` sets `quit-flag` (`:12610-12700`); `maybe_quit` throws (`eval.c:1875-1895`) | stopping any runaway command | ADR 3 as written: **no**. Commands run one at a time; keys wait in the queue | corner-risk | See Corner risk 1. |
| 51 | Quit flag, `inhibit-quit`, `with-local-quit` | `eval.c:4440-4449`; `subr.el:5525`; third C-g forces quit past `inhibit-quit` (`keyboard.c:12700-12705`) | magit (`with-local-quit`), process filters | none | later | Make `inhibit-quit` per command thread; the interrupt thunk checks it (D1). |
| 52 | `keyboard-quit` command vs `abort-recursive-edit`/`abort-minibuffers` | `simple.el:9739-9758` (clears macro definition, deactivates mark, `signal 'quit`); `minibuf.c:472-501` | all | none | later | When every command is suspended or idle, C-g works as an ordinary keymap command (no interrupt needed). `keyboard-quit` must *target* the innermost suspended command's thread, not its own thread (the quit belongs to the suspended reader). |
| 53 | `debug-on-quit`, `throw-on-input`, `while-no-input` | `eval.c:1881` (`throw_on_input`); `keyboard.c:3876` sets quit-flag to the tag when input arrives; `subr.el:5542` | consult async, corfu, vertico | none | later | Same interrupt channel as C-g: an input *arrival* hook (web thread) may interrupt a registered baton holder. See D1. |
| 54 | Emergency escape (repeated C-g) | `force_quit_count` (`keyboard.c:12700`) | stuck-loop recovery | none | later | Also needed for Gambit non-interruptible foreign calls; process-level watchdog is the last resort (research flagged no verified SIGINT module in this installed build). |

### F. Redisplay interplay

| # | Capability | Emacs mechanism | Relied on by | Tuna today | Status | Notes |
|---|---|---|---|---|---|---|
| 55 | Redisplay only when no input pending, coalesced | `redisplay` in `read_char` when idle | all | ADR 3 "Redisplay" | covered | Macro-fed events must *not* count as "input pending for redisplay": Emacs skips redisplay while executing a macro; mirror that (it is also faster). |
| 56 | Forced redisplay mid-command (`redisplay`, `sit-for`, `force-mode-line-update`, progress messages) | `Fredisplay`, `sit-for` | magit, long-running commands, `message` then compute | ADR 3 renders after command completes/suspends | later | Provide `(yield-for-render)` — an explicit baton hand-back point (ADR 4 already allows commands to yield "at explicit suspension points"). |
| 57 | Echo area, `message`, `*Messages*`, `message-log-max`, `with-temp-message`, `current-message`, echo-keystrokes | `message` → echo area + log buffer | everything | ADR 3 mentions echo area for errors only | later | Echo area is part of frame render; messages buffer is an ordinary buffer. `echo-keystrokes` is a loop timer showing pending prefix (can merge with row 28). |
| 58 | `y-or-n-p`, `yes-or-no-p`, `read-char-choice`, `read-answer` | `subr.el:3773,4148`; `read-key`-based by default, minibuffer-based with `use-short-answers` | countless | ADR 3 ("`y-or-n-p`" named) | covered | `y-or-n-p` needs the raw-key target (row 32). |

### G. Minibuffer and completion

| # | Capability | Emacs mechanism | Relied on by | Tuna today | Status | Notes |
|---|---|---|---|---|---|---|
| 59 | Minibuffer is a buffer with its own keymap, hooks, history | `read_minibuf` (`minibuf.c:573`), `minibuffer-local-map`, `minibuffer-setup-hook` | vertico, consult, corfu, embark, marginalia, flash | ADR 6 ("minibuffer … single text node"), ADR 3 | covered | `minibuffer-setup-hook`, `minibuffer-with-setup-hook`, buffer-local `post-command-hook` in the minibuffer all depend only on the buffer abstraction + hooks. 10 of the 17 packages I grepped use `minibuffer-setup-hook`. |
| 60 | `read-from-minibuffer`, `read-string`, `read-number`, `read-file-name`, `read-passwd` | `minibuf.c:1304` | everything | ADR 3 | covered | |
| 61 | Minibuffer history, `history-length`, `savehist` | `Minibuffer History` node | all | ADR 5 (session slots persist histories) | covered | |
| 62 | `completing-read`, completion tables as functions (`complete-with-action`), `completion-table-dynamic` | `minibuf.texi` "Programmed Completion" (:1956) | vertico, consult, cape, orderless, embark | none | later | Tables are closures; they read live editor objects (e.g. buffer list) so by ADR 4 they run on the baton. See D5 for the pure/offloadable variant. |
| 63 | Completion metadata and categories (`completion-metadata`, `category`, `affixation-function`, `group-function`) | `completion-metadata` used by vertico, consult, marginalia, orderless, embark, corfu, cape | the entire modern completion stack | none | later | Plain data; no architecture conflict. |
| 64 | `completion-styles`, `completion-category-overrides`, `completion-at-point-functions` (capf) | `completion-in-region` (`minibuffer.el`) | corfu, cape, magit | none | later | Capf reads buffer text at point: baton-only unless it returns a pure descriptor. |
| 65 | `enable-recursive-minibuffers`, minibuffer depth, exit via `exit-minibuffer` (throws `exit`) | `minibuffer.el:3031-3069` | embark `quit-and-run` pattern (`embark.el:2035`) | ADR 3 | covered | Exit = resume suspended command with answer; abort = resume with quit; both wake a specific thread (row 52). "Exit minibuffer, then run action after the command" works because post-command hook runs after the *exit* command (row 18). |
| 66 | Async/incremental completion UIs (vertico candidate filtering per keystroke) | synchronous Lisp in `post-command-hook`; consult uses `while-no-input`/`throw-on-input` | vertico, consult-async | ADR 3 jobs | divergence | Jobs on snapshots can filter/score candidates off the baton and post a coherent candidate list. D5. |

### H. Timers and waiting

| # | Capability | Emacs mechanism | Relied on by | Tuna today | Status | Notes |
|---|---|---|---|---|---|---|
| 67 | `run-with-timer`, `run-at-time`, `cancel-timer`, `timer-list` | `timer.el`; `timer_check` (`keyboard.c:4914`) polled from `read_char` waits | autosave, hl-line, magit, flash | ADR 2 lists "timers" as a context contribution; ADR 3 silent on delivery | later | Timer fires as a loop message; callback runs under the baton like a short command (own thread) so it can suspend. Registered via context ⇒ cancelled on deactivation (improves on Emacs; D7). |
| 68 | Idle timers, `current-idle-time`, `timer-idle-list` | `keyboard.c:14227` | hydra, magit, which-key, auto-save | ADR 5 ("idle") | later | The loop owns the input clock; "idle since" = time of last *user* event (not macro events, not job results). |
| 69 | `with-timeout`, `sleep-for` | `subr.el` | magit | none | later | Suspension with timeout. |
| 70 | `while-no-input`, `throw-on-input`, `input-pending-p` cooperation | row 53 | consult, corfu, vertico | none | later | |
| 71 | Process filters/sentinels run in the loop | `accept-process-output`, `process-filter` | magit, eglot, comint | ADR 3 ("reader threads post messages into the loop") | covered | Priority: user input first (ADR 3). |

### I. Mouse, menus, input methods

| # | Capability | Emacs mechanism | Relied on by | Tuna today | Status | Notes |
|---|---|---|---|---|---|---|
| 72 | Mouse clicks, drags, double/triple, wheel, `mouse-movement` | `commands.texi` "Mouse Events" (:1608+) | mouse users, `mouse-drag-region` | ADR 7: "later"; stable node ids | corner-risk (small) | Client computes text offset from DOM; stale-frame mismatch (Corner risk 7). |
| 73 | `mouse-face`, `help-echo`, tooltips | text properties | hover UI | ADR 7 renderer | later | `mouse-face` can be CSS `:hover`, zero server round trip; `help-echo` needs hover event or pre-sent `title`. Improves latency over Emacs. |
| 74 | Context menus, menu bar, tool bar | `context-menu-mode`, `menu-bar-mode`, `tool-bar-mode` | GUI Emacs | ADR 7 | later (shallow) | Render from `[menu-bar]`/`[tool-bar]` keymaps; keep keymap-as-menu data model. |
| 75 | Input methods (quail), `input-method-function` | `keyboard.c:3224-3307`: for ordinary chars, `read_char` calls the function, which itself reads events | CJK, TeX input | ADR 7 ("Full IME support is later work") | later | The input-method function is a suspended reader (row 32) placed *before* keymap resolution: the loop needs a pre-resolution filter stage ("if input-method is active and event is self-inserting, route to the method's target"). |
| 76 | Browser IME composition (`compositionstart/update/end`), mobile virtual keyboards | n/a | CJK users, Android | ADR 7: plugin captures composition "later", no contenteditable | corner-risk (small) | Mobile keyboards often emit `keydown` with `key: "Unidentified"`, keyCode 229 [web: Stack Overflow links in Sources]; the keydown-only plugin loses text on Android. Needs a hidden input sink (or EditContext, Chromium: <https://developer.mozilla.org/en-US/docs/Web/API/EditContext_API>) feeding `beforeinput`/composition events as typed events. |
| 77 | Text composition (`composition` property, ligatures, bidi) | display engine | Arabic/Indic | ADR 7 browser renders | covered | Browser text shaping is a net win over Emacs; point/column semantics are the buffer lane's problem. |

### J. Event transport specifics

| # | Capability | Emacs mechanism | Tuna today | Status | Notes |
|---|---|---|---|---|---|
| 78 | Ordered, at-most-once key delivery | terminal stream | `frontend/tuna-keyboard.ts` sends one POST at a time, drops on failure (`queue.shift()` in `finally`), comment says failure "does not prove the command was not executed" | later | Add a client-assigned sequence number and ack to detect gaps/dupes; macros recorded from lossy streams would be wrong. Also throughput is one HTTP round trip per key (acceptable locally, slow for pasted input) [inf]. |
| 79 | Typeahead while busy | OS tty buffer | ADR 3: queue; 204 on receipt | covered | |
| 80 | Multi-tab/multi-user input | one KBOARD per terminal; `frame-terminal` | ADR 7: all tabs mirror one frame | later | Events need `client` id; per-client `InputSession` possible later (Open question 1). |
| 81 | Held-key repeat | OS autorepeat; `repeat` field in event | `repeat: boolean` in schema | covered | Rate limit by frame cap (ADR 3). |

## Corner risks

### 1. C-g cannot interrupt a command that holds the baton

- **Capability:** quitting runaway commands (`keyboard-quit`, `abort-recursive-edit`, `while-no-input`, `with-local-quit`).
- **ADR sentences:** ADR 3 "Input … The loop dequeues events, resolves keys through the active keymaps, and runs the resulting command"; "The editor loop owns the baton and lends it to one command at a time"; Consequences: "Long-running Scheme computation in a command … does delay subsequent commands." Nothing provides an out-of-band path, and nothing lets the queue be read while a command runs.
- **Scenario:** a user runs a Scheme command that loops on a large buffer (or `M-x` something with an unforeseen O(n²) cost). They press `C-g`. The browser POSTs it, the web thread acks `204` and enqueues it. The editor loop is parked waiting for the command, so the key is never dequeued until the command ends. The user waits or kills the process. Answer to the owner's example: **no, as written**.
- **Mechanism (Emacs):** the quit char is recognized when stored (`keyboard.c:3794-3842`), setting `quit-flag` (`:12700-12705`); the evaluator checks it (`eval.c:1875-1895`). Pressing it three times overrides `inhibit-quit` (`:12700-12703`).
- **Verified on Gerbil v0.19-dev-63** [exp]: `thread-interrupt!` runs a thunk in the *target* thread. (a) On a thread spinning in `(let lp () (lp))`, a thunk doing `(raise 'quit)` is caught by that thread's `with-catch`/`with-exception-catcher`, its `dynamic-wind` after-thunk runs, and a `parameterize`d binding is visible inside the handler. (b) The same works on a thread blocked in `channel-get` (state `waiting`): it wakes, unwinds, returns `(caught quit)`. (c) `thread-terminate!` does *not* run `dynamic-wind` after-thunks (confirms research and Gambit manual `gambit.txi:10386`). (d) A child thread inherits the creator's `parameterize` bindings (Gambit manual `gambit.txi:10169`). (e) **Quirk:** when the interrupt thunk escapes (raise or continuation jump), the *caller* of `thread-interrupt!` receives an `abandoned-mutex-exception`; the target is unwound correctly. Wrapping the call in `with-exception-catcher` swallows it. A thunk that merely sets a flag gives no error.
- **Smallest change to ADR 3:** add three sentences. (i) The web layer recognizes the configured quit event at enqueue time (an immutable cell, readable off the baton) and calls `request-quit!`. (ii) `request-quit!` interrupts the current baton-holder thread with a thunk that raises `quit` unless that thread's `inhibit-quit` is set, in which case it sets a pending flag checked at the end of the inhibited region. (iii) The queue is readable by the baton holder (`input-pending-p`, `discard-input`). Leave the exact interrupt API open; note the Gambit quirk and the non-interruptible-foreign-call limit (pre-SMP the whole runtime stalls inside a long C call; same limit as Emacs).

### 2. Suspended commands may resume out of order; global-binding restore assumes LIFO

- **Capability:** `let`-style temporary state around a suspension (`(let ((inhibit-quit t)) (read-string …))`, `enable-recursive-minibuffers`, `overriding-terminal-local-map`, `current-prefix-arg`), recursive minibuffers.
- **ADR sentence:** ADR 3 "At most one command holds the baton; several may be suspended." Resume order is unspecified.
- **Scenario:** command A sets loop state X to 1 (saves 0) and suspends on a prompt; command B (e.g. a timer callback or a command in another tab) sets X to 2 (saves 1) and suspends; A's prompt is answered first and restores 0; B later restores 1: the final value 1 is wrong forever. Emacs cannot hit this because recursive edits nest strictly (the innermost minibuffer must exit first).
- **Smallest change:** state that suspended commands form a stack and answers are delivered innermost-first (other input targets are inert until the innermost resumes), or that any loop-visible state a command overrides is per-thread (Gambit `parameterize` is thread-local and inherited by children [exp]) rather than save/restore of a shared slot. Recommend both: stack for input targets; parameters for `let`-style bindings.

### 3. Dynamic binding is rejected twice but pervasive in the command loop

- **Capability:** `this-command`, `current-prefix-arg`, `unread-command-events`, `inhibit-quit`, `overriding-*`, `case-fold-search`, `minibuffer-completion-table`, `inhibit-read-only`, etc. are routinely `let`-bound by callers and hooks.
- **ADR sentences:** ADR 1: dynamic scope "Rejected for now"; ADR 4: "Buffer-local and scoped values … implemented as ordinary data in owning objects, not as dynamic variables."
- **Scenario:** a ported package does `(let ((current-prefix-arg 4)) (call-interactively #'foo))` or `(let ((inhibit-quit t)) …)`. With no dynamic-variable facility there is nothing to port it to except hand-rewritten save/restore code, which row 2 shows is unsound under suspension. Magit alone has 29 files mentioning `current-prefix-arg`.
- **Smallest change:** add to ADR 4 that command-loop variables are *thread-scoped* `parameterize`-style values with global defaults (Gambit parameters already inherit into child threads [exp]), distinct from buffer/mode/global scoped settings, and name the macro (`with-vars`/`let-dynamic`). Not a new language semantics (ADR 1 stays).

### 4. Reverse-order receipts break overlapping keymap (and similar) effects

- **Capability:** deactivate/reload plugins without collateral damage; layered keymaps.
- **ADR sentence:** ADR 2 "Deactivating a plugin runs the receipt's inverses in reverse order."
- **Scenario:** plugin A binds `C-c k` (inverse: restore "unbound"); plugin B later rebinds `C-c k` to its own command. Deactivating A first runs A's inverse and erases B's binding. Hooks (named entries) and commands registries are commutative; keymap slots, variables (`setq`), service slots are not.
- **Smallest change:** state that keymap bindings (and any slot-valued effect) are stored as owner-tagged entries/layers; inverse = "remove my entry". Effective binding = highest-priority live entry. This also gives `describe-key` the full provenance Emacs cannot show.

### 5. Browser-reserved keys

- **Capability:** the Emacs default keyset in a browser tab.
- **ADR sentence:** ADR 7: "A small Datastar plugin captures keyboard … events and POSTs them." Overview: "The browser acts like a terminal."
- **Evidence:** Chrome and Safari do not let pages `preventDefault()` browser shortcuts such as Ctrl-T, Ctrl-N (WHATWG fullscreen issue #39: <https://github.com/whatwg/fullscreen/issues/39>). The Keyboard Lock API can capture them in fullscreen only, Chromium only, and from Chrome 130 needs a permission (<https://developer.chrome.com/docs/capabilities/web-apis/keyboard-lock>; MDN <https://developer.mozilla.org/en-US/docs/Web/API/Keyboard_API>). Firefox/Edge allow `preventDefault` of Ctrl-T/N in fullscreen per the same issue.
- **Scenario:** `C-n`/`C-w`/`C-t` (next-line, kill-region, transpose-chars) open or close tabs in a normal Chrome tab; the user must live in fullscreen or use alternates.
- **Smallest change:** ADR 7 states that key capture is best-effort per client, the plugin reports a capability set (e.g. `keyboard-lock?`), and a native shell (e.g. a webview app) is an allowed first-class client. Keep an alternate-binding layer (via `key-translation-map` equivalent) for unreachable keys. [inf: the conclusion; the facts are cited.]

### 6. Input events lack identity (client, sequence)

- **Capability:** per-client prefix state, macro correctness, `last-event-frame`, dedupe.
- **ADR/code:** ADR 7 "initially every browser tab mirrors the same editor frame"; `frontend/tuna-keyboard.ts` sends no client id or sequence number; failed POSTs are dropped.
- **Scenario:** tab A types `C-x`; tab B types `2`; Tuna runs `split-window-below`. A dropped POST silently changes a recorded macro.
- **Smallest change:** schema v1→include `client` (random per page load) and a per-client monotonically increasing `seq`; server records both in the loop's input record. Cheap now, costly to retrofit.

### 7. Mouse events need the frame epoch they were computed against

- **Capability:** click-to-position, drag selection, `posn-point`.
- **ADR sentence:** ADR 7 "Rendered elements carry stable node identifiers so clicks … can be mapped back to nodes and positions" with whole-frame morphs and server-side viewport slicing.
- **Scenario:** the user clicks in frame N; three frames later (typed text above shifted offsets) the click arrives; the server maps the click's DOM-relative offset against the current viewport: wrong position.
- **Smallest change:** frame sequence/revision stamp on every pointer event; server keeps a short history of viewport→offset maps (or rejects stale clicks). Also lets `mouse-movement`/drag events be rate-limited sanely.

## Proposed divergences (improvements over Emacs)

### D1. Preemptible quit with per-thread `inhibit-quit`
- **Emacs:** quit is polled at `maybe_quit` points in C and Lisp; `inhibit-quit` is global. Tight loops in C or in long `re-search-forward` calls can ignore C-g.
- **Tuna:** `request-quit!` interrupts the baton holder (Gambit `thread-interrupt!` raising `quit`); `inhibit-quit` is thread-scoped; `while-no-input` / `with-local-quit` are the same primitive with different thunks; abort of suspended commands resumes them with a quit exception so cleanup runs (do not use `thread-terminate!`, which skips `dynamic-wind` [exp]).
- **Why better:** any Scheme loop is interruptible, not just those that poll; `with-local-quit` regions become safer.
- **Cost:** the Gambit abandoned-mutex quirk (swallow in a helper); interrupts landing mid-critical-section in non-`with-lock` code (policy: core data structure ops are not preempted; a `without-interrupts` region form); foreign calls remain uninterruptible.
- **Porting impact:** none visible; `quit` condition, `inhibit-quit`, `with-local-quit` keep names. Code that *relies* on being uninterruptible between two Lisp forms must wrap in `(with-inhibited-quit …)`, which Emacs code already does when it matters.

### D2. Owner-tagged keymap layers + node-scoped keymaps
- **Emacs:** `define-key` mutates one shared keymap; precedence is the fixed list in `current-active-maps`.
- **Tuna:** a keymap is a set of owner-tagged entries (plugin id, priority); lookup merges. Additionally, focus-node attributes may carry keymaps consulted from the focused node up its ancestors (DOM-style bubbling) before buffer/mode maps (rich-node buffers per ADR 6).
- **Why better:** exact undo on plugin deactivation (Corner risk 4), `describe-key` shows who bound what, rich buffers get local bindings without text-property hacks.
- **Cost:** keymap objects are not Emacs lists; `define-key` on a shared map becomes "add entry owned by caller's plugin".
- **Porting:** `keymap-set`/`define-keymap`/`define-key` calls port as-is; code that destructures `(keymap …)` lists, or `copy-keymap`+`setcdr`, must change (rare).

### D3. Structured command argument descriptors (compat reader for interactive strings)
- **Emacs:** `(interactive "p\nr")` strings or a Lisp form; hard to introspect beyond completion.
- **Tuna:** per-parameter descriptors (`prefix: numeric|raw`, `region`, `prompt`, `event`, …) attached to the `defcommand` parameter list; compile `interactive` code strings from ported code into descriptors.
- **Why better:** M-x/forms/macros/remote UIs can show argument types, validate, and replay semantically (D4).
- **Cost:** a translator for `interactive` forms that call Lisp (`(interactive (list …))`) — keep the form-evaluating variant.
- **Porting:** mostly mechanical; `(interactive "r")` etc. map 1:1.

### D4. Optional command-level macros alongside key macros
- Record `(command, resolved-args)` as a second track. Replay by keys (Emacs-compatible) remains default; command replay is immune to keymap/mode differences between record and replay. Cost: double bookkeeping. Porting: none.

### D5. Completion on jobs
- **Emacs:** completion table functions run synchronously in the command loop; consult async uses `while-no-input`.
- **Tuna:** tables may declare themselves *pure* (inputs: immutable candidate snapshot + query) and run as keyed jobs (ADR 3) with stale-result rejection; impure tables (read live editor objects) run on the baton as today.
- **Why better:** vertico-style filtering of 100k candidates doesn't delay keystrokes.
- **Cost:** a second table protocol; candidates must be immutable data.
- **Porting:** function tables (`complete-with-action`) port unchanged and run on the baton.

### D6. Per-activation command context instead of mutable globals
- **Emacs:** `this-command` clobbered by inner commands; `M-x` patches it (`simple.el:2636-2645`).
- **Tuna:** each running command thread has a context (command, original command, prefix arg, keys, replayed?) in a parameter; `this-command` reads the current activation; `last-command` is set when the activation *completes*. Fixes post-minibuffer `this-command` confusion.
- **Cost:** `(setq this-command 'foo)` idiom (used to chain with undo/kill) must be a setter on the context. **Porting:** names unchanged.

### D7. Timers and idle timers via plugin contexts
- Timers registered through the context are cancelled on deactivation, named for replace-on-re-register; no leaked timers after reload. Cost: bare `run-with-timer` outside a context needs an owner (default: the calling plugin or `init`). Porting: `run-with-timer` calls port as-is.

### D8. Pending-prefix inspection as a first-class loop API
- Because the loop (not an idle timer polling `this-command-keys`) owns pending keys, it can expose `(pending-prefix)` and `(bindings-under prefix)` and render the panel in the frame at once; `which-key`, `C-h` after a prefix, and `echo-keystrokes` unify. Cost: none material. Porting: `this-command-keys`, `this-single-command-keys`, `prefix-help-command`, `key-binding` keep working.

### D9. Deterministic macro replay
- Defer job results/process output/timers during replay except in explicit waits (row 45). Emacs does this implicitly; Tuna must do it explicitly because job results are an additional async source. Cost: replayed commands that start jobs and *don't* wait see no results until the macro finishes; same as Emacs for processes. Porting: none.

### D10. Hover via CSS
- `mouse-face` as `:hover`, `help-echo` as `title`/pre-rendered popover: no server round trip. Cost: properties can't depend on server state at hover time. Porting: `mouse-face`/`help-echo` text properties map directly; function-valued `help-echo` needs pre-evaluation or a hover event.

## Emacs equivalence notes

| Tuna term | Emacs term | Notes |
|---|---|---|
| Editor baton | Global interpreter lock (`global_lock`) held by the main thread; also "Lisp executing, not waiting" | Near miss: Emacs's lock is about Lisp threads; Tuna's baton also gives *suspension* semantics, which in Emacs is the recursive command loop on the C stack. |
| Editor loop + command thread | `command_loop_1` (`keyboard.c:1318`) + the C stack/`recursive_edit_1` | Tuna: one thread per command; Emacs: one stack, recursion for suspension. |
| Suspended command | Command inside `recursive-edit`/minibuffer | Resume order: Emacs LIFO enforced by the stack; Tuna must say so (Corner risk 2). |
| Input target stack | `minibuffer-depth`, `overriding-terminal-local-map`, `unread-command-events`, `read-key` modal readers | No single Emacs object; Tuna names it. |
| `InputSession` (proposed) | `KBOARD` (`keyboard.h`): `last-command`, `real-last-command`, `last-repeatable-command`, `prefix-arg`, `overriding-terminal-local-map`, `input-decode-map`, `local-function-key-map`, `defining-kbd-macro`, `Vlast_kbd_macro` | `this-command` itself is *not* per-KBOARD (global `Vthis_command`, `keyboard.c:13808`). |
| `this-command` | `this-command` (global C variable) | In Tuna: current activation context (D6). |
| Plugin context / receipt | none (best-effort `unload-feature`) | |
| `defcommand` | `defun` + `(interactive …)` | Overview example lacks an interactive spec; see rows 2–3. |
| `define-key` (ADR 1) | `define-key` (old, `kbd`/vector/char-list) vs `keymap-set` (new, `"C-f"` strings) | **Near-miss:** the overview writes `(define-key global-map "C-f" forward-char)`; in Emacs `"C-f"` as a string to `define-key` means the three characters. Tuna's `define-key` should take `keymap-set` syntax and probably be named `keymap-set` or document the break. |
| Job | async process/thread (`make-thread`, `make-process`) with no snapshot semantics | No Emacs equivalent for revision-checked results. |
| Frame (ADR 7) | *redisplay output of a window system frame* / "glass" | **Near-miss:** Emacs "frame" = top-level window; Tuna "frame" = one rendered drawing. Use `redisplay-frame`/`render` in code to avoid confusion with Emacs `frame`. |
| Quit key recognized at enqueue | `quit_char`/`set-quit-char` | Same concept. |
| Input record (proposed) | `struct input_event`, `last-input-event` | |
| Macro source (proposed) | `executing-kbd-macro` + `executing_kbd_macro_index` | Emacs reads from macro inside `read_char` (`keyboard.c:2659-2678`). |
| `request-quit!` | `quit-flag := t` | |
| Minibuffer answer delivered to waiting thread | `throw 'exit` unwinds to `recursive_edit_1` (`minibuffer.el:3046`) | Tuna returns a value; `exit-minibuffer` becomes "complete answer". |
| Suspension reason `any-input` (sit-for) | `sit-for` returning nil when input pending | |

## Open questions for the owner

1. **One input session or one per browser client?** Context: ADR 7 mirrors every tab onto one frame. Emacs gives each terminal its own KBOARD (prefix state, last-command, macro). Options: (a) one global `InputSession` (simplest; tabs share prefix and macro state); (b) one per client (tmux "two clients" semantics; macros/recorded state don't cross-contaminate); (c) design for (b), ship (a). Recommend (c): require `client` + `seq` on events now (Corner risk 6), keep `InputSession` an object.
2. **Is a desktop shell (webview/Electron) an acceptable first-class client?** Context: normal Chrome/Safari tabs cannot receive `C-n/C-w/C-t`. Options: fullscreen + Keyboard Lock (Chromium only, permission), a native shell, alternate default bindings (e.g. `C-n`→`<down>`), or accept the limitation. Recommend: support Keyboard Lock where available, ship a documented alternate-binding layer, treat a native shell as optional later.
3. **How strict must macros be about replaying keys vs commands?** Context: key replay is Emacs-compatible and handles prompts; command-level replay survives keymap changes but diverges from `C-x e` expectations. Recommend: keys by default, command-level as an opt-in second track (D4).
4. **Should async job results be deferred during macro replay by default?** (D9) Recommend yes, with an opt-out for macros that intentionally wait for a job.
5. **Dynamic-variable facility name/shape.** ADR 1/4 reject Elisp dynamic scope but command-loop state needs thread-scoped binding. Options: explicit `with-vars`, reuse Gerbil `parameterize`. Recommend: `parameterize` with a documented list of loop-scoped parameters.

## Sources

Emacs source (commit 541f693c) in `/home/jay/Code/emacs`:
- `src/keyboard.c`: command loop (:1318-1650), kbd-macro handling (:977-992, :2659-2678), quit-char/interrupt (:3794-3842, :12610-12760), `read_key_sequence` (:10901), `timer_check` (:4914), `DEFVAR_KBOARD` slots (:13781-14209), `throw-on-input` (:3876, :14292), `input-method-function` use (:3224-3307).
- `src/eval.c:1875-1895` (`process_quit_flag`), :4440-4449 (`quit-flag`, `inhibit-quit`).
- `src/keymap.c:1650-1740` (`current-active-maps`), :1532-1563 (minor/emulation maps), :3375-3382.
- `src/macros.c:276-420` (`execute-kbd-macro`, nested command loop), :435.
- `src/minibuf.c:56,573-912,1304,2236,2599`; `lisp/minibuffer.el:3031-3069`.
- `lisp/subr.el`: `kbd` :1258, `read-key` :3603, `sit-for` :3852, `y-or-n-p` :4148, `with-local-quit` :5525, `while-no-input` :5542, `set-transient-map` :7009.
- `lisp/simple.el`: `execute-extended-command` :2601 (`this-command` fix :2636-2645), `kill-region` :5886, `universal-argument` area :5455-5511, `keyboard-quit` :9739.
- `lisp/keymap.el:44,328,594`; `lisp/repeat.el:200`; `lisp/which-key.el:799`.
- Manual: `doc/lispref/commands.texi` (Interactive Codes :341, Command Modes :647, Command Loop Info :1068, Mouse Events :1608, Quitting :4164, Prefix Command Arguments :4296, Recursive Editing :4436, Keyboard Macros :4672), `keymaps.texi` (Active Keymaps :1043, Translation Keymaps :1954, Menu Keymaps :2388), `minibuf.texi` (Programmed Completion :1956, Recursive Mini :2791), `os.texi` (Timers :2239, Idle Timers :2427).

Installed packages (`/home/jay/.config/emacs/var/elpaca/sources/`): meow (`meow-core.el:167-171`, `meow-util.el:197-200`), hel (`hel-core.el:65,497-539`, `hel-scroll.el:114-153`), hydra (`hydra.el:107-132`), transient (`transient.el:2399-2406,2831-2832`), embark (`embark.el:2035-2043`), plus a file-count grep over vertico, consult, corfu, embark, magit, transient, hydra, meow, avy, marginalia, cape, orderless, flash, hel (counts quoted in rows 14, 40, 59).

Gerbil/Gambit: `gerbil/src/gambit/doc/gambit.txi` (`thread-interrupt!` :5401, user-interrupt :5505, `thread-terminate!` :10386, thread dynamic-env inheritance :10165-10180, per-thread dynamic env :11125); `gerbil/src/gambit/lib/_thread.scm:1255-1285` (`thread-interrupt!`); `/home/jay/Code/workbench-gerbil/tuna/agents/research/workbench-gerbil/gerbil-command-loop-concurrency-primitives.md` (prior research; its claim that forced termination skips cleanup is confirmed by [exp]).

Own experiments (this session, `gxi` from `/opt/gerbil/bin`, Gerbil v0.19-dev-63, scripts in `/tmp/t1..t8.ss`, not committed): interrupt a busy thread with a raising thunk → caught + `dynamic-wind` after-thunk ran; interrupt a thread blocked on `channel-get` → woke, unwound; caller of `thread-interrupt!` got `abandoned-mutex-exception` whenever the thunk escaped; `thread-terminate!` left `dynamic-wind` after-thunk unrun; `parameterize` bindings inherited by `make-thread`/`spawn`; spawn+join ≈ 1 µs.

Web:
- Keyboard Lock/Map API (MDN): <https://developer.mozilla.org/en-US/docs/Web/API/Keyboard_API>
- Keyboard Lock (Chrome, permission from Chrome 130): <https://developer.chrome.com/docs/capabilities/web-apis/keyboard-lock>; spec <https://wicg.github.io/keyboard-lock/>
- Reserved shortcut behavior in fullscreen: <https://github.com/whatwg/fullscreen/issues/39>
- Android keyboards emit `key: "Unidentified"`/keyCode 229 (community reports, medium confidence): <https://stackoverflow.com/questions/68065687/keyboard-event-event-key-is-unidentified-on-android-webview>, <https://stackoverflow.com/questions/59426933/key-code-from-keyboardevent-in-android-is-unidentified>
- EditContext API (IME for custom editors, Chromium): <https://developer.mozilla.org/en-US/docs/Web/API/EditContext_API>

Repo: `tuna/docs/overview.md`; `tuna/agents/adr/0001`–`0007`; `tuna/frontend/tuna-keyboard.ts`; `tuna/tuna/main.ss`.
