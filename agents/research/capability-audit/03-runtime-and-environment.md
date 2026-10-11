# Lane 3: Lisp runtime, extension mechanisms, and environment

Scope: variables and scoping, customization, functions/advice, hooks, features/loading/packages, introspection, errors/debugging, evaluation, processes, threads, files, encodings, server, persistence packages, kill ring, security. Depth: strong on variables, advice/hooks/loading, errors/quit, processes/threads, files/encoding, persistence, security. **Shallow:** package.el/use-package/package-vc (only mapped conceptually, no source read), native compilation, serial ports, profiler internals, Info-manual format, `emacsclient` protocol, kill-ring/interprogram paste detail (browser clipboard belongs to another lane).

Evidence conventions: "ADR n" = `/home/jay/Code/workbench-gerbil/tuna/agents/adr/000n-*.md`. Gerbil paths are under `/home/jay/Code/workbench-gerbil/gerbil/src/` (abbrev. `G/`). Emacs paths are under `/home/jay/Code/emacs/` (abbrev. `E/`). **Fact** = read in source/manual; **Inference** = my reasoning. I ran two probes on `/opt/gerbil/bin/gxi` (results in Corner risk 7).

## Summary

1. **Corner risk: no way to interrupt a running command (C-g / `quit`).** ADR 3 gives the loop a baton it lends to one command, and says long computation "delays subsequent commands", but defines no abort path. Gambit can do it (`thread-interrupt!`, `G/gambit/doc/gambit.txi:5401`, used at `G/std/net/repl.ss:203`) but the input path must be specified to watch for the quit key *while a command holds the baton*. (CR-1)
2. **Corner risk: ADR 4's "not as dynamic variables" with first-hit scope resolution** leaves out `let`-binding of settings (`case-fold-search`, `inhibit-read-only`, `default-directory`, `inhibit-modification-hooks`…), which is pervasive in Emacs code. Gerbil has per-thread `parameterize`, so a dynamic *override layer* fits, but it must be part of the scope-resolution order now, as must per-setting merge rules (hooks, `font-lock-defaults`) and an *open* scope chain (project/dir-locals, connection-local, window, frame). (CR-2, CR-3)
3. **Corner risk: advice restricted to "commands and service methods"** (ADR 1 Consequences, ADR 2 Decision). Emacs packages advise arbitrary named functions (`advice-add`) and function-valued places (`add-function`). Allow context-registered advice on any export of a `separate` module, with receipt inversion. (CR-4)
4. **Corner risk: file and process access has no seam for remote files** (TRAMP, `file-name-handler-alist`, `process-file`). ADR 5 says "the visited file"; ADR 3 says "subprocesses". Make the Files plugin and process spawning go through a path-dispatching service from day one. (CR-5)
5. **Corner risk: reload of plugins that own `defclass` state or define structs.** Gerbil reload re-evaluates definitions and creates new type descriptors; old instances become stale. ADR 5 session slots are the natural fix (save → reload → restore) but ADR 2's reload recipe does not say so. (CR-6)
6. **Corner risk: "positions are Unicode code points" cannot represent invalid UTF-8 bytes.** Gambit rejects surrogate code points (probe: `(integer->char #xDC80)` → "Out of range"), so no surrogateescape trick; `find-file-literally`/binary files/mixed-encoding files need a defined byte-escape mapping and a decoded-with record. (CR-7)
7. **Corner risk (low): plugin manifest absent.** ADR 2 learns commands only by running the activation procedure, so M-x/describe/key help/autoload for non-activated plugins and fast startup are impossible. Add a static manifest. (CR-8)
8. **Gerbil facilities check out** for most of this lane: parameters are thread-inherited, `with-exception-handler` is a `handler-bind` equivalent, `try/catch/finally` is `condition-case`, `import-module path #t #t` reloads interpreted modules, `open-process` supports `pseudo-terminal:`, `environment:`, `directory:`, `std/os/inotify` provides Linux file notification. **Gaps:** no pty window-size control in documented settings, no serial, no portable file-notify (kqueue is separate), no docstrings/symbol-file for plain `def`, no `unload`.
9. **Best improvements over Emacs:** (a) resumable debugger — a failing command thread can be *left suspended* at the raise point inside ADR 3's baton model and resumed or restarted; (b) plugin dependency activation replaces `eval-after-load`; (c) typed settings make file-local/dir-local safety checkable by schema instead of per-symbol `safe-local-variable` predicates; (d) hook callbacks that error are disabled individually, with a message; (e) reload with automatic state round-trip through session slots.

## Inventory

Status values: covered, later, corner-risk, divergence. "Tuna today" cites ADRs; `—` means the ADRs say nothing.

### A. Variables and scoping

| # | Capability | Emacs mechanism / equivalent | Relied on by | Tuna today (ADR) | Status | Notes |
|---|---|---|---|---|---|---|
| A1 | Lexical binding | `lexical-binding: t`; `let` (`E/doc/lispref/variables.texi` "Variable Scoping") | All modern Elisp | Gerbil is lexical (ADR 1) | covered | Gerbil `let` is always lexical. |
| A2 | Special (dynamic) variable binding with `let` | `defvar`-declared specials; specpdl (`variables.texi:1125` "Dynamic Binding") | `case-fold-search`, `inhibit-read-only`, `default-directory`, `standard-output`, `debug-on-error`, `deactivate-mark`, `print-length`… | "not as dynamic variables" (ADR 4 last bullet); "no dynamic-binding design yet" | corner-risk | CR-2. Gerbil has `parameterize` → `call-with-parameters` → Gambit `##parameterize1` (`G/gerbil/core/more-sugar.ss:70`, `G/gerbil/runtime/control.ss:31`). Per-thread; a new thread **inherits** the creator's dynamic environment (`gambit.txi:10165-10167`). |
| A3 | `defvar` plain global (non-custom) state: `last-command`, `this-command`, `current-prefix-arg`, `kill-ring`, `unread-command-events` | global symbol value | Command loop, every minor mode | Plugin-owned state objects (ADR 4) | covered | Fits "ordinary mutable objects". Porting cost: `(setq last-command …)` becomes a field access. |
| A4 | Buffer-local variables: `make-local-variable`, `setq-local`, `buffer-local-value`, `kill-local-variable`, `local-variable-p` | per-buffer alist (`variables.texi:1445,1539`) | Modes, `major-mode`, `fill-column`, `tab-width` | "Buffer-local and scoped values … node, buffer, mode, global" (ADR 4); Buffer owns "buffer-local values" (ADR 6) | covered | `setq-local` ≙ set on buffer scope. |
| A5 | `make-variable-buffer-local` (automatic locality) | variable flag: any `setq` creates a local binding | `fill-column`, `indent-tabs-mode`, `major-mode`… | — | later | Setting declaration flag `auto-local`. Distinguish from `setq-default`. |
| A6 | `setq-default`/`default-value`/`set-default` | global default slot | init files | global scope (ADR 4) | covered | Name mapping in Equivalence notes. |
| A7 | `permanent-local` property | survives `kill-all-local-variables` (mode change) | `buffer-file-name`, `major-mode` hooks, `permanent-local-hook` | — | later | Setting flag `survives-mode-change`. Mode-scoped values (ADR 4 "mode" scope) already give a cleaner structure: mode switch just changes the active mode scope, so only *buffer*-scope entries need the flag. |
| A8 | Scope chain beyond 4 levels: window-local, frame parameters, terminal params, **connection-local**, **directory-local/project** | `window-parameter`, `connection-local-set-profiles` (`variables.texi:2392,2408`), `dir-locals` (`:2240`) | TRAMP, Eglot, project.el, `.dir-locals.el` | Fixed list "node, buffer, mode, global" (ADR 4) | corner-risk | CR-3. Chain must be open and ordered by a registry. |
| A9 | Per-setting combine rule (merge vs shadow) | hooks' `t` element; `minor-mode-map-alist`; `font-lock-extra-managed-props` | Hooks, keymaps, text properties | "resolve from the most specific scope outward" (first-hit) | corner-risk | CR-3. |
| A10 | Variable watchers | `add-variable-watcher` (`variables.texi:905`) | `customize`, `font-lock`, `which-key`, Magit refresh | Revisions on renderable objects (ADR 4) | later | Tuna can give every setting a revision + change hook; also drives render invalidation (divergence D5). |
| A11 | Variable aliases / obsolete variables | `defvaralias`, `make-obsolete-variable` (`variables.texi:2691`) | Package renames | — | later | Registry alias table, warns once on use. |
| A12 | Variables with restricted values | `defcustom :type`, `:safe`, `defvar-keymap`… (`variables.texi:2792`) | customize UI, safety | `defcustom` named in ADR 1 prelude, no type spec described | later | The `:type` must be *data* (schema) so the UI, validation (ADR 5 "validated"), and safety (S2) share it. |
| A13 | File-local variables (`-*- … -*-`, `Local Variables:` block) | `hack-local-variables` (`variables.texi:1986`) | Source files in the wild | — | later | Parsing is plain text; application = write buffer-scope settings. Safety: S1–S3. |
| A14 | Directory-local variables | `.dir-locals.el`, `dir-locals-set-class-variables` (`variables.texi:2240`) | Projects (indent style, `compile-command`) | — | later | `.dir-locals.el` is an alist of data; Scheme `read` can mostly parse it (no `?c`, `#'`), `eval` entries are code → S3. Needs project scope (A8). |
| A15 | Connection-local variables | profiles bound to remote connection (`variables.texi:2392`) | TRAMP remote shells | — | later | Depends on file-system seam (CR-5). |

### B. Customization

| # | Capability | Emacs equivalent | Relied on by | Tuna today | Status | Notes |
|---|---|---|---|---|---|---|
| B1 | `defcustom` | `E/doc/lispref/customize.texi` | Every package | `defcustom` in prelude (ADR 1); persisted in `custom.ss` (ADR 5) | covered | Needs `:type`, `:group`, `:set`/`:initialize`, `:safe`, `:local` keys. |
| B2 | Customize UI (widgets) | `M-x customize` | Users | Settings "changed through Tuna's UI" (overview); buffers are node trees (ADR 6) | later | Natural fit for rich node buffers: forms as nodes. Better than Emacs widget.el (D6). |
| B3 | `custom-file` | code file with `custom-set-variables` | init.el hygiene | `custom.ss` as **data**, never evaluated (ADR 5) | covered | Behavior difference: Emacs custom-file runs `:set` functions as code at load. Tuna restore must call each setting's setter after the owning plugin activates; also must **preserve unknown keys** of disabled plugins (ADR 5 says this only for session slots). Minor gap; add to ADR 5. |
| B4 | `:set` side effects and `:initialize` order | `custom-initialize-*` | `global-*-mode` customs | — | later | `custom.ss` apply order = plugin activation order, init.ss last (ADR 2). |
| B5 | Custom themes (`deftheme`, `custom-theme-set-faces`, `load-theme`, enable/disable stack) | `E/doc/lispref/customize.texi` "Custom Themes" | Every theme package | Renderer is HTML with CSS custom properties (ADR 7) | divergence | D6: theme = named layer of settings + CSS custom properties, enabled/disabled through a context (receipt reverses it). Faces as data, not `defface` symbols. Cost: face-name compat shim for ported packages. |
| B6 | Faces (`defface`, face inheritance) | face symbols | All modes | text properties (ADR 6) but faces not discussed | later | Out of this lane; flagged for the rendering lane. |

### C. Functions and advice

| # | Capability | Emacs equivalent | Relied on by | Tuna today | Status | Notes |
|---|---|---|---|---|---|---|
| C1 | Symbol function cell, `fset`, `defalias`, `symbol-function` | `E/doc/lispref/functions.texi` | Everything; `(defalias 'foo #'bar)` | Gerbil modules; no cells (ADR 1, "does not rewrite `def`") | divergence | Names are lexical bindings; aliasing = re-export or `(def foo bar)`. Porting: `defalias` → `def`; `fset` on foreign function → only via `separate` + `set!`. |
| C2 | Redefine any function at runtime (monkey-patch) | `(defun foo …)` again, `fset` | User init, hot-fixing | `separate` modules + `set!`; module reload (ADR 1) | covered | Fact: ADR 1's compile check (block vs separate). Inference: the exact mechanism for an *external* `set!` of an imported binding needs a documented helper, since Gerbil normally forbids assigning imports; ADR 1 states it works but not how. |
| C3 | `advice-add` on any named function (`:around :before :after :override :filter-args :filter-return :before-while :before-until :after-while :after-until`) | `nadvice` (`functions.texi:1912,2139`) | Hundreds of packages (Magit, Evil, Doom) | Advice only on commands and service methods (ADR 1, ADR 2) | corner-risk | CR-4. Note ADR 2 lists six combinators; Emacs has 12 (adds the `*-while/*-until` four plus `:override`/`filter-*` already counted). Port impact: `:before-while`/`:after-until` etc. are used for guards (e.g. `:before-while` to veto). Cheap to include. |
| C4 | `add-function` / `remove-function` on places (`(local 'fn-var)`, `(process-filter p)`) | `functions.texi` "Core Advising Primitives" | `completion-at-point-functions`-style variables, `process-filter`, `eldoc` | — | later | Function-valued slots are ordinary object slots; provide an advice wrapper over a slot accessor. |
| C5 | Advice removal on package unload | `advice-remove` manual | — | Context receipt reverses advice (ADR 2) | covered | Improvement over Emacs. |
| C6 | Obsolete aliases/functions | `make-obsolete`, `define-obsolete-function-alias` (`functions.texi:2479`) | Package evolution | — | later | Registry "deprecated-name" table warning once. Gerbil has `:std/deprecation` (`G/std/deprecation.ss`). |
| C7 | `interactive` spec, `call-interactively`, `commandp` | `commands.texi` | M-x, keymaps | `defcommand` (ADR 1) | covered | `(interactive "p")` codes need a mapping to `defcommand` parameter kinds. Out of lane detail. |
| C8 | `called-interactively-p`, `current-prefix-arg` | — | Many commands | — | later | Command invocation record (ADR 3 thread-per-command can carry it). |

### D. Hooks

| # | Capability | Emacs equivalent | Relied on by | Tuna today | Status | Notes |
|---|---|---|---|---|---|---|
| D1 | `add-hook`/`remove-hook`, depth ordering | `E/doc/lispref/modes.texi:35,147` | All modes | Named ordered hooks (depth then registration) (ADR 2) | covered | Names replace function-equality removal. Porting: `(add-hook 'h #'f)` → name derived from `f` (see Equivalence). |
| D2 | Buffer-local hooks (`add-hook … nil t`, `t` marker in value, `permanent-local-hook`) | local hook value includes `t` meaning "also run global" | Mode setup (`flymake`, `eglot`) | Settings scope (ADR 4) is shadowing, hooks are "named, ordered lists" (ADR 2) | corner-risk | CR-3 (merge combiner). Hooks must be a scoped, *merging* setting. |
| D3 | Run variants: `run-hooks`, `run-hook-with-args`, `-until-success`, `-until-failure`, `run-hook-wrapped`, abnormal hooks (`-functions`) | `modes.texi` | `after-change-functions`, `completion-at-point-functions` | — | later | Hook declaration (`defhook`) carries a "combination mode" (all/until-success/until-failure/wrapped/args). |
| D4 | Hook error handling | In `run-hooks`, an error propagates; for `before/after-change-functions` Emacs resets the hook to nil on error (`E/doc/lispref/modes.texi` hook notes; behavior also visible in `src/insdel.c`, **not re-verified**) | Robustness of editing | "Change hooks run synchronously … must be cheap" (ADR 3); errors reported, loop continues | divergence | D4: disable only the failing callback and report; keep the rest. Cost: none for ports. |
| D5 | Hooks inside commands before/after (`pre-command-hook`, `post-command-hook`) | `commands.texi` | `which-key`, `cursor-sensor`, `delete-selection-mode` | Commands are loop-driven (ADR 3) | later | Loop must call them *inside* baton lend; error in these in Emacs unsets the hook. |
| D6 | Timers: `run-at-time`, `run-with-idle-timer`, `cancel-timer` | `os.texi` "Timers" | Autosave, `eldoc`, `company`, `flycheck` | Timers are context contributions (ADR 2); idle semantics undefined (ADR 3) | later | Idle = input queue empty for N ms (loop knows). Timer callbacks run on editor thread with baton. |

### E. Features, loading, packages

| # | Capability | Emacs equivalent | Relied on by | Tuna today | Status | Notes |
|---|---|---|---|---|---|---|
| E1 | `provide`/`require`/`featurep` | `loading.texi` | All packages | Plugins named; Gerbil `import` for code (ADR 1/2) | divergence | Two layers: Gerbil modules (static `import`) and plugins (runtime dependency graph via services). `require` of a plugin = activate it. |
| E2 | `load`, `load-file`, `load-path`, `load-history` | `loading.texi` | Init | Gerbil: `load-module`, `add-load-path!` (`G/gerbil/runtime/loader.ss:14-24,32`), `GERBIL_LOADPATH` | covered | No `load-history`; source→definition tracking must be recorded by prelude forms (E7). |
| E3 | Autoload and `;;;###autoload` cookies | `loading.texi:529,820`; `eval.texi:538` | Startup time, M-x discovery | Activation procedure registers commands (ADR 2) | corner-risk (low) | CR-8. Need a static manifest so commands/keys/modes can be listed before code loads. |
| E4 | `eval-after-load` / `with-eval-after-load` | `loading.texi` | Every `use-package :config` | Plugin dependencies / service dependencies activate and deactivate dynamically (ADR 2, Cordis) | divergence | D2. `(after-plugin 'x thunk)` via context is reversible; Emacs's is permanent. Porting impact: `with-eval-after-load` bodies that `setq` globals rely on running exactly once; reversible form re-runs on each reactivation. |
| E5 | `unload-feature` and its limits | `loading.texi:1248` | Rare | Plugin deactivate via receipt (ADR 2) | covered | The limit in Emacs is that it only reverses a known list of side effects (hooks, advice via `unload-feature-special-hooks`); Tuna's receipt records effects at registration. **What receipts cannot undo:** (1) effects outside the context, (2) module-level `def`s and the Gerbil module table (Gerbil has `reload-module!` but no unload; `G/gerbil/runtime/loader.ss:75`), (3) `defclass`/`defstruct` descriptors. See CR-6. |
| E6 | Reload | `load-library` again | Dev | Plugin deactivate → reload modules → activate (ADR 2) | covered | Fact: `reload-module!` only reloads when the stored state is a `.scm` source path or a *newer* compiled file path; compiled `.o` of the same path is not re-`dlopen`ed (`loader.ss:75-100`, `__find-library-module` numbers compiled files). Interpreted reload: `(import-module path #t #t)` (`G/gerbil/expander/module.ss:93`); `std/interactive` wraps this with dependents (`G/std/interactive.ss:8-60`). So: **packages reload from source (interpreted); core is compiled and not reloadable** — consistent with ADR 1 "not supported". |
| E7 | Definition location and docstrings for every function | `symbol-file`, `find-function`, `documentation` | Help, xref | `defcommand` takes a docstring (overview) | later | Gerbil `def` carries no docstring or load history that I found; only registry forms (commands, customs, hooks, services) can record doc + source location (syntax object source). `describe-function` on an arbitrary Gerbil procedure gives only arity/name. Be explicit that "introspection coverage = registered things". |
| E8 | package.el (archives, install, quickstart), `use-package`, `package-vc` | `E/lisp/emacs-lisp/package.el`, `use-package`, `package-vc.el` | Package ecosystem | Gerbil packages via `gxpkg` (`G/…/gxpkg`, not read) | later | Shallow. Tuna package manager = `gxpkg` + plugin manifest; `use-package` ≙ `defplugin` + settings. Not an architecture blocker. |
| E9 | Byte/native compilation | `.elc`, `.eln` | Performance | Gerbil compiles via `gxc`; `separate` for redefinable modules (ADR 1) | covered | Packages ship as source or compiled; reload is interpreted. Interpreted code is much slower than `gxc` code (inference); hot plugins should be compiled and reloaded by version-suffixed output. |

### F. Help and introspection

| # | Capability | Emacs equivalent | Relied on by | Tuna today | Status | Notes |
|---|---|---|---|---|---|---|
| F1 | `describe-function/variable/key/mode`, `where-is` | `E/doc/lispref/help.texi` | Everyone | Registries (commands, keymaps, settings) via contexts (ADR 2) | later | All data exists in registries because everything goes through contexts. Receipt gives "which plugin defined this binding" — Emacs cannot answer that. |
| F2 | `substitute-command-keys` | `help.texi` | Docstrings | — | later | Docstrings with `\\[command]` markup render as nodes with links. |
| F3 | `apropos` | symbol table scan | Discovery | Registry scan | later | Cannot search arbitrary Gerbil bindings except via `(list-modules)`/expander tables (`G/std/interactive.ss`). |
| F4 | `find-function`, xref to definitions | `symbol-file` | Dev | Source location in registrations (E7) | later | As E7. |
| F5 | Info manuals | `info` | Docs | Rich buffers (ADR 6) | later | Render Info or Markdown into a node-tree buffer; hyperlink nodes. |
| F6 | Self-documenting keymaps and mode lines | `describe-bindings` | Users | Keymap objects (ADR 4) | later | — |

### G. Errors, debugging, profiling

| # | Capability | Emacs equivalent | Relied on by | Tuna today | Status | Notes |
|---|---|---|---|---|---|---|
| G1 | `signal` / `error` / `user-error` | `E/doc/lispref/control.texi` | All | Gerbil `raise`, `error` (std/error `Error` class `G/gerbil/runtime/error.ss:20`) | covered | Gerbil can raise any object. |
| G2 | `condition-case`, `ignore-errors`, `unwind-protect` | `control.texi:2302` | All | `try/catch/finally` (`G/gerbil/core/more-sugar.ss:133`), `unwind-protect` (`:85`) | covered | `catch` clauses can dispatch on predicate/type (inference from `try` syntax; not exhaustively read). |
| G3 | `handler-bind` (handler runs at signal point, no unwind) | Emacs 30 `handler-bind` (`control.texi:2619`) | Debugger, `debug-on-error` | `with-exception-handler` (`G/gerbil/runtime/error.ss:60`) | covered | Runs in the raise context; `raise-continuable` gives resumption (Emacs lacks it). |
| G4 | Error symbol hierarchy (`error-conditions`) | `define-error` | Handlers by class | Gerbil `defclass` hierarchy of `Error` | covered | Mapping: error symbol ↔ class; `file-error` etc. map to `std/os/error` classes. |
| G5 | `debug-on-error`, backtrace buffer, debugger | `E/lisp/emacs-lisp/debug.el` | Dev | Command error "reported in echo area; loop continues" (ADR 3) | divergence | D1: error handler captures continuation (`continuation-capture`, `G/gambit/doc/gambit.txi:5186`); backtrace via `display-continuation-backtrace` (`G/gerbil/runtime/error.ss:174`; hook `__unhandled-actor-exception-hook`, `G/gerbil/runtime/thread.ss`). Because commands are threads (ADR 3), the failed command thread can stay parked and be resumed/aborted — a debugger with *restarts*. |
| G6 | `toggle-debug-on-quit`, `debug-on-signal` | — | Debugging hangs | See CR-1 | later | Depends on quit design. |
| G7 | Edebug instrumentation | `E/lisp/emacs-lisp/edebug.el` | Dev | — | later | Edebug rewrites forms via specs. For Gerbil: no equivalent infrastructure; a debugger plugin can use Gambit's `##step`/breakpoints via the REPL or macro-wrapped `defcommand` bodies (inference). Marked low priority. |
| G8 | Profiler (CPU/memory) | `profiler.el` samples backtraces on SIGPROF | Perf | — | later | Gambit has `##process-times`, `##gc-report`; statistical profiler `std/debug/...`? only `DBG.ss` found (`G/std/debug/DBG.ss`). A sampler thread calling `thread-interrupt!` on the editor thread to capture `continuation-capture` is plausible (inference, untested). |

### H. Evaluation

| # | Capability | Emacs equivalent | Relied on by | Tuna today | Status | Notes |
|---|---|---|---|---|---|---|
| H1 | `eval-expression` (M-:), `eval-last-sexp` (C-x C-e), `eval-defun`, `eval-buffer`, `eval-region` | `eval.texi`, `elisp-mode.el` | Daily Elisp use | ADR 1: runtime `eval` OK except under full-program optimization | covered | Gerbil `eval` needs the expander loaded (ADR 1 notes FPO failure `Unbound variable: __eval-import`). Need: an eval environment module importing `:tuna/prelude`. Evaluating a `defcommand` must register into some context: see Open Question 2. |
| H2 | Which plugin owns what you eval in scratch | implicit global | `*scratch*` hacking | Top-level of a file belongs to its plugin; init.ss is a plugin (ADR 2) | later | Needs a "current eval plugin" (dynamic, used at load time only). That is a dynamic variable in the prelude — fine with ADR 4 as it is not a setting, but record it. |
| H3 | `ielm` / REPL-in-buffer | `ielm.el` | Dev | `std/net/repl` attached REPL exists (`G/std/net/repl.ss`, exports `start-repl-server!`) | later | ielm = a buffer with an evaluator command; no new corner. |
| H4 | `*scratch*` buffer, `lisp-interaction-mode` | — | Everyone | A buffer kind (ADR 6) | covered | — |
| H5 | `read` of buffer text with positions | `read-from-string`, `scan-sexps` | eval-last-sexp, paredit | Gerbil reader/`read-syntax` exists in expander (not exhaustively read) | later | Needs a TextStore→port adaptor with offsets (code-point). ADR 6 slicing/chunk iteration suffices. |

### I. Processes

| # | Capability | Emacs equivalent | Relied on by | Tuna today | Status | Notes |
|---|---|---|---|---|---|---|
| I1 | `make-process` (pipe) with filter and sentinel | `E/doc/lispref/processes.texi:729,1829,2186` | LSP, magit, compile | Subprocesses with reader threads posting into the loop (ADR 3); context-registered (ADR 2) | covered | Filter ≙ message handler on editor thread; sentinel ≙ exit message. Gambit `open-process` settings `stdin-redirection`, `stdout-redirection`, `stderr-redirection`, `environment:`, `directory:`, `pseudo-terminal:` (`G/gambit/doc/gambit.txi:15935-15955`; wrapper `G/std/misc/process.ss:44-65`). |
| I2 | pty vs pipe | `process-connection-type` | Shells, REPLs, `comint`, term | `pseudo-terminal: #t` supported on UNIX | covered / gap | Fact: setting exists. Gap (inference from documented settings): no documented window-size (`TIOCSWINSZ`) or termios control — needs a small FFI for terminal emulators. |
| I3 | `accept-process-output`, synchronous waiting for output | `processes.texi` | magit, `call-process` wrappers, `eglot-sync` | Commands can suspend waiting for answers (ADR 3) | covered | Natural: command thread blocks on a process channel while suspended (baton returned). Better than Emacs: no re-entrancy hazard of filters running inside the wait. Porting: filters never run *during* `accept-process-output`; code that relies on that for side effects needs rewriting. |
| I4 | `call-process`, `process-file`, `shell-command` | `processes.texi` | Everything | `std/misc/process` `run-process` (`G/std/misc/process.ss:45`) | covered | Blocking calls inside a command hold the baton and freeze the loop; offer a baton-yielding variant by default (divergence D7). |
| I5 | `process-environment`, `exec-path`, `default-directory` | globals | All spawn code | `environment:`/`directory:` keywords | later | These become dynamic settings (CR-2) honored by spawner. |
| I6 | Network processes and servers | `make-network-process` | `url.el`, `elnode`, `server.el` | `std/net/socket`, `std/net/ssl`, `std/net/http` exist | covered | — |
| I7 | Serial ports | `make-serial-process` | Embedded dev | No Gerbil std support found | later | Gap: FFI to `termios`; not blocking. |
| I8 | Process kill/signal, `process-query-on-exit-flag`, orphan cleanup | `processes.texi` | Safety | Context receipts cancel subprocesses on deactivate (ADR 2) | covered | Improvement over Emacs. Gerbil caveat: `process-status` can hang when `add-signal-handler!` is used (documented by gerbil-mcp tooling; not verified here). |

### J. Threads and concurrency

| # | Capability | Emacs equivalent | Relied on by | Tuna today | Status | Notes |
|---|---|---|---|---|---|---|
| J1 | `make-thread`, `thread-join`, `thread-yield`, `thread-signal` | `E/doc/lispref/threads.texi:58,97,110`; cooperative, one global lock, switches only at yield points | Rare (a few async libs) | Gambit preemptive green threads; editor mutation only under baton (ADR 3/4) | divergence | D8: Tuna threads are preemptive; user threads must not touch editor objects except via `run-on-editor`. Porting impact: Emacs threads that mutate buffers need restructuring. `thread-signal` ≙ `thread-interrupt!` (`gambit.txi:5401`). |
| J2 | Mutex, condition variable | `make-mutex`, `condition-wait` | Thread code | Gambit `make-mutex`, `condition-variable-*` (`gambit.txi:9911-9949,10875-10925`); `std/sync` | covered | Non-recursive mutexes; Gambit conditions can wake spuriously. |
| J3 | Global lock semantics and yield points | Only at I/O waits and `thread-yield` | Atomicity assumptions in Elisp | Baton: commands yield only at suspension points (ADR 3/4) | covered | Same property for commands; ADR 4's "commands do not yield the baton mid-edit" relies on it. **But** Gambit green threads are preemptive: any code in the command thread that is interrupted by the scheduler does not release the baton, so atomicity holds only against *other baton users*, not against interrupt thunks injected by the quit mechanism (CR-1). |
| J4 | Thread-local dynamic state | Per-thread `specpdl` | `let` bindings | Parameters inherited at thread creation (`gambit.txi:10165`) | later | Command threads inherit the *loop thread's* environment, not the invoking context: loop must run with a clean environment (inference). |
| J5 | `with-timeout`, `sit-for`, `sleep-for`, `input-pending-p`, `while-no-input` | `os.texi` | Completion, eldoc, redisplay-aware code | — | later | `while-no-input` = interrupt on queue arrival; requires command access to the input queue (API) or the same interrupt path as CR-1. |
| J6 | `inhibit-quit`, `with-local-quit` | `commands.texi` | Critical sections | — | later | Needs a dynamic "quit-inhibited" flag consulted by interrupt thunk. |

### K. Files

| # | Capability | Emacs equivalent | Relied on by | Tuna today | Status | Notes |
|---|---|---|---|---|---|---|
| K1 | `find-file` pipeline: `find-file-hook`, `auto-mode-alist`, `magic-mode-alist`, `interpreter-mode-alist`, `find-file-not-found-functions`, `after-find-file` | `E/lisp/files.el`, `files.texi` | Every language mode | Files plugin (ADR 5); tables as registered data (ADR 2) | covered | Alists as ordered registrations with receipts. Order significance (first match wins) must be preserved. |
| K2 | File locking (`.#foo` symlinks, `ask-user-about-lock`) | `files.texi` | Multi-user safety | — | later | Gerbil has `std/os/flock` (`G/std/os/flock.ss`). Emacs locks are advisory symlinks; browser multi-tab session shares one editor so lock conflicts only vs other processes. |
| K3 | Backup files (`make-backup-files`, numbered backups) | `backups.texi` | Safety | ADR 5 table has no backups; overview "Disk stores … Tuna's own backups" | later | Add to ADR 5 table when built. |
| K4 | Auto-save | `auto-save-mode` | Crash recovery | `autosave/` dir, idle + timer (ADR 5) | covered | `recover-session`/`recover-this-file` equivalent needed. |
| K5 | `revert-buffer`, `auto-revert-mode` | `files.texi` | Magit, logs | — | later | Needs file-change source. |
| K6 | File notification | `file-notify-add-watch` (inotify/kqueue/w32/gfile) | auto-revert, dired | Gerbil: `std/os/inotify` (Linux; `inotify-add-watch`, `inotify` returns events or `#f` on timeout, `G/std/os/inotify.ss:59-80`), `std/os/kqueue` (BSD/macOS); no portable wrapper found | later | Reader thread posts messages (ADR 3). Wrapper plugin must pick backend by platform; no polling fallback exists in std (inference). |
| K7 | `before-save-hook`, `after-save-hook`, `write-contents-functions`, `write-file-functions` | `files.texi` | Format-on-save, `delete-trailing-whitespace` | `after-save-hook` in overview example (hooks, ADR 2) | covered | The *veto* semantics of `write-contents-functions` (non-nil return = handled) needs hook combination mode D3. |
| K8 | `file-name-handler-alist` (TRAMP, jka-compr, ange-ftp, `/:` quoting) | `files.texi` "Magic File Names" | TRAMP, `.gz`, `.age`, archive mode | — (ADR 5 "the visited file") | corner-risk | CR-5. |
| K9 | `default-directory` as per-buffer state | buffer-local var | Every file/process call | Buffer-local values (ADR 4) | covered | Must be a setting honored by file and process APIs (dynamic override per CR-2). |
| K10 | Dired, project.el | `dired.el` | Navigation | Rich node buffers (ADR 6) | later | Other lane. |
| K11 | Coding system detection, `coding:` cookie, EOL conventions, BOM, `find-file-literally`, `revert-buffer-with-coding-system` | `nonascii.texi`, `mule.el` | Every non-UTF-8 file | ADR 6: code-point offsets; bytes "never leave the store" | corner-risk | CR-7. |
| K12 | Atomic save, `file-precious-flag`, preserve permissions/ownership | `files.texi` | Safety | ADR 5 specifies temp+rename for Tuna's own files only | later | Files plugin must also do this for user files, and handle symlinks/hardlinks. |
| K13 | Large files, `so-long`, `vlf` | — | Big logs | Rope + viewport (ADR 6/7) | covered | Rope + persistent store favorable. |

### L. Server and daemon

| # | Capability | Emacs equivalent | Relied on by | Tuna today | Status | Notes |
|---|---|---|---|---|---|---|
| L1 | `emacsclient`/`server-start`/daemon | `E/lisp/server.el` | Terminal workflows, `$EDITOR` | Tuna *is* a server; browser tabs attach; sessions mirror (ADR 7) | divergence | D9: provide a `tuna-client` CLI posting to the same local server: open file, eval, `$EDITOR`/`$GIT_EDITOR` blocking wait (`--wait` = resume when buffer is "finished"). Better: attach from any tab, not just TTY. Needs `server-edit` equivalent and authentication (local socket or token). |
| L2 | Multiple frames/sessions per client | frames | Multi-monitor | "Initially every browser tab mirrors the same frame; per-tab frames later" (ADR 7) | later | Out of lane. |

### M. Persistence packages

| # | Capability | Emacs equivalent | Relied on by | Tuna today | Status | Notes |
|---|---|---|---|---|---|---|
| M1 | `savehist` | writes variables as Lisp (`E/lisp/savehist.el`) | Minibuffer histories | Session slots, plain data (ADR 5) | covered | Histories are plain lists: ideal. |
| M2 | `recentf` | `E/lisp/recentf.el` | File menu, consult | Session slot | covered | — |
| M3 | `saveplace` | alist of file→point | Reopen position | Session slot | covered | Must tolerate stale files (ADR 5 consequence). |
| M4 | `bookmark` | `E/lisp/bookmark.el` (readable alist + handlers) | Navigation | Session slot or own file | covered | Bookmark *handlers* are function symbols; store handler **name** (plugin-registered), not closure. |
| M5 | `desktop` | desktop file is Lisp, re-evaluated; per-mode restore handlers | Session restore | ADR 5 explicitly rejects evaluating state | divergence | Already deliberate. Cost: packages storing closures/markers must provide `save`/`restore` returning plain data; **registers** (markers, window configs, rectangles) need codecs; ADR 5's "restore must tolerate references to buffers that no longer exist" covers it. |
| M6 | Registers | `register.el` (text/number/marker/window-config/file) | Macros, jump | Plugin-owned state + optional slot | later | Markers are buffer-owned (ADR 6) so register-persisted markers = (buffer-ref, offset) data. |
| M7 | Minibuffer history persistence, `kill-ring` persistence (`savehist-additional-variables`) | — | Convenience | Slots | covered | — |
| M8 | `abbrev`, `tempo`, `yasnippet` user data | `abbrev-file-name` | Typing | Plugin files | later | Not core. |

### N. Kill ring, clipboard, yank

| # | Capability | Emacs equivalent | Relied on by | Tuna today | Status | Notes |
|---|---|---|---|---|---|---|
| N1 | Kill ring, `kill-ring-max`, `current-kill`, `yank`, `yank-pop` | `E/doc/lispref/text.texi:913,946` | Everyone | Plugin state (ADR 4); `kill-ring` as persisted slot optional | covered | — |
| N2 | `interprogram-cut-function` / `interprogram-paste-function` | `text.texi:259` | Clipboard integration | Browser clipboard API requires user gesture/permission; input transport "paste later" (ADR 7) | later | Cut: server → browser via a frame-side effect (needs a non-HTML channel — transport gap, flag for transport lane). Paste: browser `paste` event posts text (ADR 7 lists paste as later). |
| N3 | Yank handlers, `yank-handled-properties`, `yank-excluded-properties`, `insert-for-yank` | `text.texi:1031` | Org, `ansi-color`, `rect` | Text properties live in the text node (ADR 6) | later | Rich nodes: yank of a non-text subtree needs a defined clipboard format. |
| N4 | Rectangles, registers in kill ring | — | Edit | — | later | Out of lane. |

### O. Security and trust

| # | Capability | Emacs equivalent | Relied on by | Tuna today | Status | Notes |
|---|---|---|---|---|---|---|
| O1 | `enable-local-variables` (`:safe`, `t`, `nil`, ask) | `variables.texi:1986` | Opening untrusted files | — | later | S1. |
| O2 | `safe-local-variable` / `risky-local-variable` properties, `safe-local-eval-forms` | per-symbol predicates | Same | Typed `defcustom` (ADR 1, B1) | divergence | D3: setting's type schema is the default safety check (a `:safe` flag opts in); no per-symbol predicate maintenance. |
| O3 | Directory-local variable trust, `.dir-locals.el` `eval:` | `enable-local-eval`, `ask` | Cloned repos | — | later | Reject `eval` by default; allow only as a plugin-declared action with a trusted-project list. |
| O4 | `trusted-content` (Emacs 30; `untrusted-content`, `trusted-content-p`) | `E/lisp/files.el:710-741`: `trusted-content` is a `defcustom` list of files/dirs; `risky-local-variable` | `elisp-flymake`, `flymake`, macro-expansion on open | "Plugins are trusted in-process code. There is no sandbox." (ADR 2) | later | The ADR 2 sentence concerns plugins only; it does not decide trust for *opened content*. A trusted-content model must be separate (Open Question 3). |
| O5 | Plugin trust / supply chain | `package.el` checks signatures | Packages | "no sandbox" (ADR 2) | covered | Consistent. Document in user docs that plugin = arbitrary code including network and filesystem. |
| O6 | Browser-borne trust: other websites reaching a localhost server (CSRF, DNS rebinding) | n/a for Emacs | Tuna | — | later | Not an Emacs thing; flagged for transport lane: `/commands` POST with arbitrary key events equals arbitrary code execution (via `M-:`). Origin/Host checks and per-session token needed. |

## Corner risks

### CR-1. Running commands cannot be interrupted (no `quit`)
- **Capability:** C-g aborting a runaway command, `debug-on-quit`, `while-no-input`, `with-timeout`, `inhibit-quit`.
- **ADR text:** ADR 3: "The editor loop owns the baton and lends it to one command at a time" and "Long-running Scheme computation in a command … does delay subsequent commands." Nothing says how C-g gets through when the loop is waiting for the command. The 204-on-receipt + enqueue path (ADR 3/7) only *enqueues*.
- **Scenario:** A ported command loops forever (`while` with a bad predicate, regex backtracking). The user presses C-g; the key is queued; the loop never dequeues it; the tab is dead; only process kill helps. Emacs handles this via `quit-flag` checked in `maybe_quit` (inference from Emacs design; not re-verified in `E/src/keyboard.c` here).
- **Smallest change:** Add one sentence to ADR 3: the input enqueue path recognizes the quit key (`keyboard-quit` binding resolved by the active keymap, or a fixed `C-g`) *while a command holds the baton* and calls `thread-interrupt!` on the command thread with a thunk that raises a `quit` condition; `unwind-protect`/`dynamic-wind` cleanups then run in the command thread. Fact: `thread-interrupt!` exists (`gambit.txi:5401`) and is used this way for the REPL server (`G/std/net/repl.ss:203`). Do **not** use `thread-terminate!` (Gambit does not run cleanup; `gambit.txi:10369-10421` describes only mutex abandonment). Unverified: behavior of `thread-interrupt!` once Gerbil is SMP.

### CR-2. No dynamic-binding story for settings and context
- **Capability:** `(let ((case-fold-search nil)) …)`, `(let ((inhibit-read-only t)) …)`, `(let ((default-directory dir)) (call-process …))`, `(let ((inhibit-modification-hooks t)) …)`, `with-temp-buffer`/`save-excursion`/`save-restriction`/`with-current-buffer` as special cases, `current-buffer` itself.
- **ADR text:** ADR 4 last bullet: "implemented as ordinary data in owning objects, not as dynamic variables"; the task brief says ADR 4 has no dynamic-binding design yet.
- **Scenario:** Porting `(let ((case-fold-search nil)) (re-search-forward …))` requires either (a) a `set!`-and-restore wrapper on the buffer's scope (breaks if the command suspends in the middle and another command observes the temporary value, and is not thread-safe vs. jobs), or (b) rewriting every search function to take explicit arguments. Magit, Evil, and org use these bindings heavily (`inhibit-read-only` and `default-directory` binding is routine; I did not count occurrences).
- **Facts:** Gerbil `parameterize` expands to `call-with-parameters`/`##parameterize1` (`more-sugar.ss:70`, `control.ss:31`); threads inherit the creator's dynamic environment (`gambit.txi:10165-10167`); dynamic bindings survive command suspension since the command is a thread (ADR 3). So a dynamic **override layer** is cheap: one Gambit parameter holding an immutable map from setting-id (and scope-id) to value, consulted *before* buffer/mode/global scope; `with-setting` = `parameterize` of that parameter.
- **Smallest ADR change:** state in ADR 4 that scope resolution order is `dynamic → node → buffer → mode → … → global`, that the dynamic layer is a thread-inherited parameter introduced by a prelude `with-setting` (name TBD), and that `current-buffer` is per-command-thread state (so `with-current-buffer` is `with-setting`-like, not a global write). Tuna must pick one answer for "does a setting bound in a command also apply inside jobs it spawns?" — with inheritance (Gambit default) it does; jobs are supposed to receive plain data (ADR 3), so recommend jobs be spawned with an explicitly cleared environment. Do not rule out the layer by wording.

### CR-3. Scope resolution is first-hit, closed, and not per-setting
- **Capability:** buffer-local hooks with the `t` marker (D2), connection-local, directory/project-local, window-local, frame, terminal/tab-local values, merging settings (hooks, `font-lock-extra-managed-props`, `minor-mode-alist`).
- **ADR text:** ADR 4: "Settings resolve from the most specific scope outward (node, buffer, mode, global)". ADR 2: hooks are named ordered lists.
- **Scenario:** `eglot` adds a buffer-local `completion-at-point-functions` entry plus the global one; with first-hit semantics the buffer value *shadows* the global list, losing global entries (this is the exact reason the Emacs `t` convention exists). A TRAMP buffer needs a connection scope between buffer and global. A project scope (dir-locals) is not in the list.
- **Smallest change:** ADR 4 wording: "the chain is an ordered list registered by plugins (default: node, buffer, mode, project, connection, global); each setting declares a combiner (`shadow` default, `append`, `merge`) and hooks declare `append`." No implementation needed now.

### CR-4. Advice restricted to commands and service methods
- **Capability:** `advice-add` on arbitrary named functions; `add-function` on places; user fixes via `(advice-add 'some-pkg-fn :around …)`.
- **ADR text:** ADR 1 Consequences: "Function-level redefinition of core internals that are not exposed as services, commands, hooks, or `separate` modules is not supported. The intended extension points are services, commands, hooks, and advice on those." ADR 2: "Advice wraps commands and service methods."
- **Scenario:** A ported package (e.g., Evil advising `forward-char`-like primitives, or Magit users advising `magit-process-…`) cannot be expressed unless the target is a command or service. Users routinely advise *package-internal helper functions*.
- **Fact:** ADR 1 already permits `set!` redefinition for `separate` modules. Advice on such a function is therefore the same mechanism plus a wrapper.
- **Smallest change:** ADR 2: "Advice may also target any exported binding of a `separate` module (installed by `set!`; the receipt restores the previous value only if the binding still holds this advice's wrapper, otherwise it unlinks the advice from the chain)." Keep advice chain data in a registry so removal order is independent (`nadvice` does this). Also list the full Emacs combinator set (add `before-while`, `before-until`, `after-while`, `after-until`). Core code remains unadvisable by design; that is a deliberate, documented divergence (D10).

### CR-5. Remote/virtual file and process access has no seam
- **Capability:** TRAMP (`/ssh:host:/path`), `file-name-handler-alist` (jka-compr, archives, `/:` quoting), `process-file`/`start-file-process` honoring remote `default-directory`, connection-local variables.
- **ADR text:** ADR 5: "File contents | The visited file | Explicit save | Files plugin"; ADR 3: "Language servers, shells, and tools run as subprocesses". No path-based abstraction.
- **Scenario:** If the Files plugin, autosave, backup, file-notify, and process spawning call `file-exists?`/`open-process` directly (as `G/std/misc/process.ss` does), remote editing and compressed-file editing require touching every plugin.
- **Smallest change:** record in ADR 2/5 that file operations and process spawning are a `FileSystem`/`Spawner` **service** whose provider is chosen by path (prefix/handler registry), with the default provider being the local OS. (ADR 2's service model already supports this; it only needs naming now so the Files plugin is written against it.) Services currently are one slot with one implementation (ADR 2); handler dispatch by path needs *multiple providers keyed by pattern* — a small extension.

### CR-6. Reload and plugin-owned `defclass`/`defstruct` state
- **Capability:** `unload-feature`/reload without losing state; Tuna's headline "reload a plugin without restarting".
- **ADR text:** ADR 2 Reload: "deactivate its plugins, reload its modules, activate again"; ADR 4: "Plugins define their own state objects."
- **Fact:** reload re-evaluates definitions (`import-module path #t #t`, `module.ss:93`); a re-evaluated `defclass`/`defstruct` produces a new type descriptor (inference from Gerbil MOP; not tested here); old instances then fail type checks and method dispatch (inference). Compiled modules reload only via version-numbered files (`loader.ss:75-100`).
- **Scenario:** A plugin keeps a `(defclass diff-state …)` instance per buffer; the user edits the class and reloads; existing instances are of the old type and every method call errors.
- **Smallest change:** ADR 2: "A plugin's reload preserves state by writing its session slot (ADR 5) before deactivation and restoring it after activation; plugin state classes needing live migration must provide a `restore`." This turns ADR 5's slots into the migration path; costs nothing in the core. Also document: compiled plugins reload only if rebuilt to a new versioned artifact; interpreted source reloads always.

### CR-7. Code-point positions vs. non-Unicode bytes
- **Capability:** opening/saving files that are not valid UTF-8 without corruption (`raw-text`, `binary`, `no-conversion`, Latin-1, Shift-JIS, GBK, mixed), `find-file-literally`, hex editing, EOL preservation (LF/CRLF/CR), BOM preservation, `coding:` cookie.
- **ADR text:** ADR 6 Coordinates: "Public positions are zero-based Unicode code-point offsets. Byte offsets and internal chunking never leave the store."
- **Facts (probes on `/opt/gerbil/bin/gxi`):** `(integer->char #xDC80)` fails with "(Argument 1, n) Out of range" — Gambit rejects surrogate code points, so Python-style *surrogateescape* is not available. Reading invalid UTF-8 in `bytes->string` fails with "Invalid UTF-8 encoding". Gambit's built-in encodings are ASCII, ISO-8859-1, UTF-8, UTF-16 variants (`gambit.txi:2349-2365`; `char-encoding:` option at `:15386`); no Shift-JIS/GBK/etc. support was found in the Gambit manual.
- **Scenario:** A file with one stray 0xFF byte cannot be loaded as text and saved byte-identically unless an escape mapping exists. Emacs solves this with raw-byte pseudo-characters.
- **Smallest change:** ADR 6: "A buffer records its decoding (`coding`, `eol`, `bom`); bytes that do not decode are represented by reserved code points (e.g., a private-use range) and are re-emitted verbatim on save." Encoders/decoders for non-built-in encodings are a plugin-supplied `Coding` service (or `iconv` FFI). No change to positions.

### CR-8. No static plugin manifest (autoload equivalent)
- **Capability:** M-x listing, `describe-key`, `where-is`, auto-mode, and `autoload` before a package's code is loaded; startup cost control; `use-package :commands/:mode/:hook` deferral.
- **ADR text:** ADR 2: "A plugin is a named unit with an activation procedure that receives a context." Everything is registered by running that procedure.
- **Scenario:** 500 plugins; startup must load all to build the M-x table, or lose features.
- **Smallest change:** let `defplugin` forms also generate a static manifest (name, requires, provides, commands with docstrings, file-patterns/auto-mode entries, keybinding stubs) written at build/install time (Emacs: `loaddefs`, `;;;###autoload`). Activation of a stub-registered command loads the module and replaces the stub. Low risk (later work), but a statement that "registration implies loading" would block it.

## Proposed divergences (improvements over Emacs)

**D1. Resumable debugger.** *Emacs:* the debugger runs on top of the failing stack but you cannot resume execution after most errors; `debug` returns by unwinding. *Tuna:* handler captures the continuation in the raise context (`with-exception-handler`, `raise-continuable`) and parks the command thread (ADR 3 allows many suspended commands); the backtrace is a rich node buffer (frames as nodes); actions: abort (unwind via `thread-interrupt!` raising `quit`), return a value from a frame, retry the command. *Why better:* fix-and-continue; no half-applied command state after "no rollback" (ADR 4). *Cost:* a parked thread holds the baton unless released — the debugger must release it; stale-world hazards as in ADR 3. *Port impact:* none for ordinary code.

**D2. Dependency-driven activation replacing `eval-after-load`.** *Emacs:* `with-eval-after-load 'x body` runs once after `x` is loaded, never undone. *Tuna:* plugins declare `requires`; configuration blocks attach to an activated plugin/service and are reverted on deactivation (ADR 2, Cordis). *Better:* correct under disable/reload. *Cost:* Emacs idiom of "run body once" differs; bodies must be idempotent or use receipts. *Port impact:* mechanical rewrite of `with-eval-after-load` → `after-plugin`; the thunk may run many times.

**D3. Schema-based local-variable safety.** *Emacs:* `safe-local-variable` predicates registered per symbol; many packages omit them, producing "unsafe local variable" prompts. *Tuna:* settings have a typed schema (needed anyway for the customize UI and ADR 5 validation); file-/dir-local values are accepted automatically iff they validate and the setting is flagged `:safe`; `eval:` and `mode:` entries are separate, explicit trust decisions. *Better:* uniform safety, fewer prompts. *Cost:* must write `:type` for every `defcustom`. *Port impact:* ported `defcustom`s lack Tuna types; a compat shim could derive types from Emacs `:type` specs.

**D4. Fail-soft hooks.** *Emacs:* an error in `after-change-functions` etc. causes the whole hook variable to be set to nil (verify in `E/src/insdel.c`; I did not). *Tuna:* disable only the offending callback via its named entry, show a clickable notice, offer "re-enable". *Better:* editing keeps working with a single broken plugin. *Cost:* nondeterminism risk if callbacks assume each other. *Port impact:* none.

**D5. Settings as observable objects.** Every setting has a revision and change notification (ADR 4 revisions); renderer invalidation, modeline updates, and customize UI react. *Better:* replaces `add-variable-watcher` ad-hoc uses and `force-mode-line-update`. *Cost:* extra indirection on reads. *Port impact:* `setq` on a setting must become `set-setting!` to notify; a prelude macro `setq-local` can wrap.

**D6. Themes and customize as data + CSS.** Themes are layers of setting overrides plus CSS custom properties; the customize UI is a node-tree form generated from schemas. *Better:* instant switching, no widget.el. *Cost:* face-name compatibility shim; custom faces that use arbitrary Elisp face specs need translation. *Port impact:* theme packages need a converter.

**D7. Baton-yielding blocking calls.** `call-process`/`accept-process-output`/`sleep-for` default to a variant that returns the baton while waiting (like `read-string`, ADR 3). *Better:* the UI stays responsive during `git status`. *Cost:* the state may change across the wait; code must re-read state (already required by ADR 3). *Port impact:* code assuming nothing else runs during `call-process` can observe changes; rare but real, offer `with-baton-held` variant.

**D8. Preemptive threads with an explicit editor handoff.** Replace Emacs's cooperative threads with Gambit threads plus `run-on-editor` (post a thunk to the loop). *Better:* real concurrency, SMP-ready. *Cost:* any Emacs thread code touching buffers must be restructured. *Port impact:* low (few packages use threads).

**D9. `tuna-client` over the existing server.** Command-line client that opens files/evals/`--wait` for `$EDITOR`, via a local socket with token. *Better:* attaches from anywhere; no TTY frame needed. *Cost:* new auth surface (O6). *Port impact:* `server-edit`, `server-buffer-done-hook` map to client wait/finish.

**D10. Core internals deliberately unadvisable.** ADR 1 consequence; benefit is full optimization. *Cost:* some Emacs customizations (advising internals like `insert`) are impossible; plugins can advise services and `separate` modules (CR-4). Documented port impact: "if the package advises a C primitive, find the service method".

**D11. Reload with state round-trip** (see CR-6): automatic save → reload → restore of session slots. *Better than Emacs:* no state loss; *cost:* every stateful plugin implements slot codecs.

## Emacs equivalence notes

| Tuna term | Emacs term | Near-miss / difference |
|---|---|---|
| plugin | feature / package / minor mode | A feature is a loaded file; a plugin is a reversible unit with dependencies. Emacs `unload-feature` ≈ `deactivate` but best-effort. |
| context | none (closest: dynamic extent of `use-package`) | No Emacs object owns registrations. |
| receipt | none; `unload-feature` uses `load-history` | Receipt is forward-recorded; `load-history` is reconstructed. |
| service | no counterpart; `defgeneric`/cl-generic at best | Services are replaceable slots with dependents re-activated on change. |
| `defcommand` | `defun` + `(interactive)` | Also registers into context and carries docstring/srcloc. |
| `defcustom` | `defcustom` | Tuna: typed schema first-class, persisted as data not code. |
| `defhook` / hook | `defvar *-hook`, `add-hook` | Tuna hooks hold named callbacks; remove by name, not `equal` function. Emacs `t` in local hook value ↔ combiner `append`. |
| advice | `nadvice` | Tuna restricted target set today; same 6 (should be 12) combinators. |
| scope chain / scoped value | buffer-local + default value | Tuna: also mode/node/project/connection; Emacs has no mode-scope (major-mode variables copied locally on mode change). |
| dynamic override layer (proposed) | `let` on special variable | Per-thread, inherited; Emacs binds are global except per-thread bindings in threads. |
| `with-setting` (proposed) | `let`/`setq-local` + `unwind-protect` | — |
| baton | global lock (`thread.c`) | Emacs lock yields at I/O/`thread-yield`; baton released at explicit suspension. |
| job | `make-process`/thread/`async` | Receives immutable snapshots; result applied only if revision current — no Emacs equivalent. |
| session slot | variable in `savehist-additional-variables`, desktop handler | Data, not code; unknown slots preserved. |
| `custom.ss` | `custom-file` | Data vs code. |
| `init.ss` | `init.el` | Re-evaluation reverts previous contributions first. |
| text store / node tree | buffer text / text properties | Out of lane. |
| `quit` condition (proposed) | `quit` signal | Same name; delivered via interrupt not flag polling. |
| `tuna-client` (proposed) | `emacsclient` | — |
| `run-on-editor` (proposed) | `run-at-time 0`/`run-with-idle-timer` | Posts to loop queue. |
| activation / deactivation | enabling/disabling a mode; load/unload | A minor-mode toggle is closer than `require`. |

Near-miss warnings: Emacs `unwind-protect` runs on `thread-signal`/quit; Gambit `thread-terminate!` does **not** (no cleanup documented, `gambit.txi:10369-10421`), so Tuna must never map `thread-signal` to `thread-terminate!`. Emacs `provide` ≠ Gerbil `provide`/`export`. Gerbil `(declare (separate))` is per-module, whereas Emacs symbol-cell indirection is global.

## Open questions for the owner

1. **Dynamic binding of settings (CR-2).** Options: (a) dynamic override layer above buffer scope (Gambit parameter); (b) forbid temporary binding, require explicit-argument APIs; (c) mutate-and-restore. *Recommendation:* (a), because ported Emacs code relies on `let`-binding and the cost is one parameter lookup; decide jobs inherit-or-clear (recommend clear).
2. **What does evaluating `defcommand`/`define-key` in scratch (M-:, C-x C-e) register into?** Options: a persistent "scratch" plugin; the file's own plugin when evaluating from a plugin source buffer (reloads that definition); a throwaway context reverted at next eval. *Recommendation:* file's own plugin for source buffers, a user-visible "eval" plugin for scratch; both record receipt entries so redefinition replaces rather than duplicates.
3. **Trust model for opened content (O1–O4).** Options: Emacs-like `enable-local-variables` + trusted-content list; data-only (no `eval:`) forever; per-project trust prompts. *Recommendation:* data-only local variables validated by schema (D3), `eval:` disabled unless the project is on a trusted list.
4. **Debugger behavior (D1).** Is "park the failing command and offer restart" desired as the default instead of "echo error, continue"? *Recommendation:* default echo + `M-x debug-last-error` retaining the parked continuation for N errors; always-parking by `debug-on-error` setting.
5. **Reload semantics for compiled plugins.** Interpreted reload is simple; compiled is faster but needs versioned artifacts. *Recommendation:* develop interpreted, ship compiled; state in docs.
6. **Baton-yielding blocking calls as the default (D7).** Port compatibility vs. responsiveness. *Recommendation:* default yielding, with `with-baton-held` escape hatch.

## Sources

Tuna:
- `/home/jay/Code/workbench-gerbil/tuna/docs/overview.md`; ADRs 1–7 in `/home/jay/Code/workbench-gerbil/tuna/agents/adr/`; research index `/home/jay/Code/workbench-gerbil/tuna/agents/research/README.md`; `/home/jay/Code/workbench-gerbil/tuna/agents/research/workbench-gerbil/gerbil-command-loop-concurrency-primitives.md` (used for orientation; claims re-checked against Gerbil source where cited).

Gerbil (all `/home/jay/Code/workbench-gerbil/gerbil/src/`):
- `gerbil/core/more-sugar.ss:70` (`parameterize`), `:85` (`unwind-protect`), `:133` (`try`)
- `gerbil/runtime/control.ss:31` (`call-with-parameters`); `gerbil/runtime/error.ss:20,60,121-187` (Error class, `with-exception-handler`, `display-exception`, backtrace); `gerbil/runtime/thread.ss:27-81` (`spawn`, `thread-main` unwind handler)
- `gerbil/runtime/loader.ss:14-24,32,75-100` (`load-path`, `add-load-path!`, `load-module`, `reload-module!`); `gerbil/expander/module.ss:85-130` (`import-module`, `eval-module`); `std/interactive.ss` (reload utilities)
- `std/misc/process.ss:44-65` (`run-process`: `pseudo-terminal:`, `environment:`, `directory:`); `std/os/inotify.ss:1-80`; `std/os/kqueue.ss`; `std/os/flock.ss`; `std/net/repl.ss:203` (`thread-interrupt!` use)
- `gambit/doc/gambit.txi`: `:5186` (`continuation-capture`), `:5401` (`thread-interrupt!`), `:10165-10167` (thread inherits dynamic environment), `:10369-10421` (`thread-terminate!`), `:9911-9949,10875-10925` (mutex/condvar), `:11290` (`parameterize`), `:15935-15955` (`pseudo-terminal:`), `:2349-2365,15386` (character encodings)
- Probes run 2026-10 via `/opt/gerbil/bin/gxi -e`: `(integer->char #xDC80)` → "Out of range"; invalid UTF-8 `bytes->string` → "Invalid UTF-8 encoding".

Emacs (`/home/jay/Code/emacs`, commit `541f693c…`):
- `doc/lispref/variables.texi` (nodes at :478 Defining Variables, :905 Watching Variables, :1125 Dynamic Binding, :1445/:1539 Buffer-Local, :1986 File Local, :2240 Directory Local, :2392/:2408 Connection Local, :2691 Aliases, :2792 Restricted Values)
- `doc/lispref/functions.texi:1912,2139,2479`; `loading.texi:529,820,1248`; `eval.texi:538`; `modes.texi:35,147`; `control.texi:2302,2619`; `processes.texi:729,1829,2186`; `threads.texi:58,97,110`; `text.texi:259,913,946,1031`; `customize.texi`; `help.texi`; `files.texi`; `backups.texi`; `nonascii.texi`
- `lisp/files.el:710-741` (`untrusted-content`, `trusted-content`, `trusted-content-p`); `lisp/subr.el:8068` (`handler-bind` macro)
- Not read (referenced by name only): `lisp/server.el`, `lisp/savehist.el`, `lisp/recentf.el`, `lisp/bookmark.el`, `lisp/emacs-lisp/package.el`, `edebug.el`, `profiler.el`, `src/keyboard.c`, `src/insdel.c`.

Not searched on the web: all claims are from local sources; no external URLs were needed.
