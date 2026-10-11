# Emacs Live Extensibility Architecture

## Scope and revision

Primary-source review of `/home/jay/Code/emacs` at revision:

- `541f693ca2e8de166cfe52c39bbfc497142215e9`
- 2026-07-16, `Create macro 'pcase-let*-strict`
- Report source was read-only; no Emacs files were modified.

## Executive model

Emacs live extensibility is not one mechanism. It is a set of mutable indirection points with different contracts:

1. **Symbol cells** provide late-bound names for functions and global/dynamic values.
2. **Advice** composes named, inspectable wrappers around callable indirections.
3. **Hooks and callback fields** expose explicit lifecycle or event boundaries.
4. **Ordered registries and alists** select handlers, modes, and keymaps.
5. **The command loop and event waits** define safe-ish points for interactive and asynchronous work.
6. **Load history plus explicit unload callbacks** provides partial, best-effort reversal.
7. **Packages remain responsible for resources and state migration**; Emacs has no general ownership graph or atomic reload transaction.

The strongest transferable lesson is that live replacement works only when every relevant call crosses a maintained indirection point. Direct C calls, compiled-in expansions, anonymous captured functions, existing resources, and untracked registrations escape that model.

## 1. Function and value cells

Each interned symbol has separate value, function, property-list, and immutable print-name cells. A function cell may contain a function, macro, alias symbol, keymap, keyboard macro, or autoload object; the value cell supplies the variable’s dynamic/global value (`doc/lispref/symbols.texi:46-65`, `78-97`). This separation allows the same name to denote both a variable and function (`doc/lispref/symbols.texi:109-113`).

Function calls whose operator is a symbol repeatedly resolve its function cell until reaching a non-symbol callable. Invalid terminal objects signal `invalid-function` (`doc/lispref/eval.texi:243-263`). `symbol-function`, `fboundp`, `fmakunbound`, and `fset` expose that cell directly (`doc/lispref/functions.texi:1620-1720`).

Value-cell introspection is less complete: `symbol-value` sees the current dynamic value, but a lexical binding lives in the lexical environment and may differ (`doc/lispref/variables.texi:706-726`). Some values cannot be changed: `nil`, `t`, keywords, and several implementation variables signal `setting-constant` (`doc/lispref/variables.texi:120-148`).

### Actual use

`package-isolate` temporarily replaces the function cell of `package-activate-1` with `ignore` via `cl-letf`, preventing installation from activating a package in the current session (`lisp/emacs-lisp/package.el:2618-2631`). Tramp similarly installs temporary function-cell replacements for capability probes around remote temporary-file creation (`lisp/net/tramp.el:7108-7119`).

This demonstrates two distinct uses:

- durable redefinition through `defun`/`defalias`;
- scoped, dynamically unwound replacement for testing or capability suppression.

Named hook entries are preferable to anonymous functions because editing the named definition changes subsequent symbolic dispatch without adding a duplicate callback; `add-hook` explicitly recommends symbols for this reason (`lisp/subr.el:2338-2342`).

## 2. Redefinition, primitives, and compiled callers

`defun` replaces even primitive definitions without warning (`doc/lispref/functions.texi:760-768`). `defalias` normally delegates to `fset`, records the defining file for unloading, and permits a `defalias-fset-function` mediator (`doc/lispref/functions.texi:772-800`). Raw `fset` changes the cell but lacks that load-history bookkeeping.

Primitive-facing replacement is incomplete:

- C code commonly calls a primitive’s C implementation directly, bypassing its symbol’s replacement (`doc/lispref/functions.texi:818-827`).
- Advice on primitives has the same split behavior, and advising primitives used by advice itself can recurse indefinitely (`doc/lispref/functions.texi:2189-2200`).
- Native-compiled Lisp at optimization level 2 or above needs generated trampolines to observe primitive advice/redefinition. If generation is disabled or fails, calls ignore the replacement (`doc/lispref/compile.texi:1117-1139`).
- The trampoline runtime warns that redefining essential primitives can break trampoline machinery (`lisp/emacs-lisp/comp-run.el:392-425`).
- Inlined calls retain the old body until callers are recompiled and do not behave reliably with tracing or advice (`doc/lispref/functions.texi:2566-2598`).
- Already macro-expanded code likewise retains the old expansion (`doc/lispref/functions.texi:2189-2192`).

**High severity:** a primitive replacement can produce two simultaneous semantics—indirect Lisp calls see the replacement while C or optimized native calls retain the original.

### Actual use and caution

`socks.el` optionally advises `open-network-stream`, but its source calls this “a terrible idea” and notes historical signature incompatibility (`lisp/net/socks.el:328-336`). This is a concrete example of why replacing a broad primitive-facing API is fragile.

## 3. Advice: composition, ordering, redefinition, and removal

Advice is a reversible composition layer for function values (`add-function`) and named functions (`advice-add`), rather than wholesale replacement (`doc/lispref/functions.texi:1920-1933`). Combinators include:

- `:before`, `:after`;
- `:override`, `:around`;
- short-circuiting `:before/after-while` and `-until`;
- argument and return filters (`doc/lispref/functions.texi:2235-2344`).

Advice properties include a stable `name` and numeric `depth`. Lower depth is outermost; equal-depth advice is newest-outermost. For `:before`, outermost executes first; for `:after`, outermost executes last (`doc/lispref/functions.texi:2029-2058`).

Named advice survives normal `defun`/`defalias` redefinition because `advice-add` installs a `defalias-fset-function` wrapper. On replacement, nadvice strips stale wrappers, substitutes the new underlying function into the existing advice chain, and preserves pending advice for undefined or autoloaded names (`lisp/emacs-lisp/nadvice.el:459-503`, `509-537`). Direct low-level mutation remains more likely to bypass bookkeeping.

Removal can identify advice by function or stable name; `advice-member-p` and `advice-mapc` support discovery (`doc/lispref/functions.texi:2210-2233`). Special forms cannot be advised (`lisp/emacs-lisp/nadvice.el:441-445`).

### Actual use

`trace.el` installs named, depth `-100` around-advice so tracing is outermost, records non-local exits with `unwind-protect`, tests membership by name, and removes it without disturbing other advice (`lisp/emacs-lisp/trace.el:222-257`, `310-327`).

`electric-indent-mode` first removes its prior advice/hook and then conditionally reinstalls them, making reconfiguration idempotent (`lisp/electric.el:251-286`).

**Medium severity:** advice changes assumptions for every caller and complicates debugging. The manual recommends hooks or key remapping instead and notes that built-in Emacs code generally avoids advice (`doc/lispref/functions.texi:2158-2187`).

## 4. Normal and abnormal hooks

A normal hook is conventionally named `-hook`, contains functions called with no arguments, and is normally run via `run-hooks`. Abnormal hooks commonly end in `-functions`, receive documented arguments, and may use return values (`doc/lispref/modes.texi:35-76`).

Abnormal runners encode protocol semantics:

- `run-hook-with-args`: broadcast;
- `...-until-failure`: veto chain;
- `...-until-success`: first successful handler wins (`doc/lispref/modes.texi:125-145`).

`add-hook` is duplicate-resistant, supports global and buffer-local registration, and orders functions by depth. A local hook contains `t` as a sentinel requesting inclusion of the global value (`doc/lispref/modes.texi:170-228`). Equal-depth ordering and depth storage are implemented explicitly in `subr.el` (`lisp/subr.el:2311-2399`).

### Actual use

- `kill-buffer-query-functions` forms a veto protocol: `find-alternate-file` aborts when any member returns false (`lisp/files.el:2178-2201`).
- Saving allows `write-contents-functions` or `write-file-functions` to claim responsibility by returning non-`nil`; otherwise normal writing proceeds (`lisp/files.el:6138-6185`).
- `file-name-at-point-functions` is a first-success provider chain (`lisp/minibuffer.el:3907-3927`).
- Flymake uses the abnormal `flymake-diagnostic-functions` hook as a backend protocol whose first argument is a report callback and whose remaining arguments are extensible keywords (`lisp/progmodes/flymake.el:695-718`).

Transferable distinction: broadcast notifications and handler-selection protocols should not share an underspecified “callback list” abstraction.

## 5. Registries, alists, and handler protocols

### File-name handlers

`file-name-handler-alist` maps regexps to handler functions. File primitives pass the operation symbol plus original arguments to the selected handler (`doc/lispref/files.texi:3328-3369`). When multiple handlers match, the match starting latest in the filename wins, allowing compression to wrap remote access (`doc/lispref/files.texi:3392-3395`).

Handlers must either implement an operation or delegate to the original primitive while dynamically inhibiting themselves for that operation. Incorrect inhibition causes recursion or breaks composition with other handlers (`doc/lispref/files.texi:3523-3559`). An `operations` symbol property limits dispatch and avoids unnecessarily loading autoloaded handlers (`doc/lispref/files.texi:3572-3587`).

Tramp is the representative implementation:

- it uses the documented inhibition protocol to delegate (`lisp/net/tramp.el:2421-2439`);
- maintains backend operation alists and adds/removes advice for external operations (`lisp/net/tramp.el:2617-2692`);
- installs an autoload handler before full package load (`lisp/net/tramp.el:2800-2830`);
- replaces the autoload handler with concrete handlers and deliberately reorders compression/encryption handlers (`lisp/net/tramp.el:2855-2896`);
- removes its handler entries during unload (`lisp/net/tramp.el:2938-2947`).

**Medium severity:** this is a broad protocol with subtle precedence and recursion rules; new operations can expand handler obligations.

### Mode registries

Mode selection is layered: explicit file settings, interpreter registry, content-magic registry, then filename registry (`doc/lispref/modes.texi:664-676`). `auto-mode-alist` is first-match ordered, while `magic-mode-alist` dispatches by content (`doc/lispref/modes.texi:716-779`). Built-in entries include image, Org, Emacs Lisp, and language modes (`lisp/files.el:3037-3075`).

This is effective live configuration, but it is mutable global order rather than a namespaced registration service.

## 6. Command-loop boundaries, keymaps, and modes

The command loop reads a sequence, resolves it through active keymaps, creates an undo boundary, and invokes the command (`doc/lispref/commands.texi:35-71`). `pre-command-hook` and `post-command-hook` bracket each command; post-command also runs after quit or error (`doc/lispref/commands.texi:73-90`).

These hooks have unusual failure isolation: quitting is inhibited; an erroneous hook function is silenced and removed, while remaining functions continue (`doc/lispref/commands.texi:92-100`). Unhandled command errors flush pending input and return to the top-level loop via `command-error-function` (`doc/lispref/control.texi:2260-2290`).

Recursive command loops suspend an outer command but retain ordinary command availability and error boundaries. The manual discourages them for most applications in favor of temporary modes (`doc/lispref/commands.texi:4438-4491`).

### Actual use

- Isearch installs a terminal-overriding map, then uses pre/post-command hooks to decide whether an unrecognized command exits search (`lisp/isearch.el:1330-1354`, `3185-3219`).
- Repeat mode attaches metadata (`repeat-map`) to command symbols, installs command-boundary hooks, creates a transient map, and explicitly cancels its timer/map on exit (`lisp/repeat.el:425-460`, `550-578`).

### Keymap precedence

Active keymaps are layered: terminal override, local override, text/overlay maps, emulation maps, minor-mode overrides/maps, major-mode local map, then global map (`doc/lispref/keymaps.texi:1055-1102`, `1125-1148`). Earlier minor-mode entries win, although modes are expected not to depend on this ordering (`doc/lispref/keymaps.texi:1248-1271`).

Command remapping changes a command semantically without enumerating every binding, but remapping is only one level deep (`doc/lispref/keymaps.texi:1894-1938`). This is safer than global function advice when behavior should vary by active context.

Major-mode entry is expected to be idempotent (`doc/lispref/modes.texi:350-389`), while changing mode runs cleanup and resets most buffer-local state. Derived modes inherit maps and run ancestor then child hooks (`doc/lispref/modes.texi:549-572`, `867-905`). Minor-mode bodies and hooks run on both enable and disable, so teardown must branch on mode state (`doc/lispref/modes.texi:1831-1937`).

## 7. Processes, filters, and sentinels

A process filter receives all process output as `(process, string)`. Output arrives only at selected waits and may recursively invoke the filter if the filter itself waits (`doc/lispref/processes.texi:1828-1847`). Chunk boundaries are arbitrary; protocol tokens may be split across calls (`doc/lispref/processes.texi:1919-1928`).

Filters can be replaced immediately or composed with `add-function` (`doc/lispref/processes.texi:1930-1945`). Errors are normally caught and displayed without aborting the interrupted program; quit is inhibited (`doc/lispref/processes.texi:1852-1867`). C code restores the caller’s current buffer after filter execution (`src/process.c:6350-6362`).

Sentinels receive status transitions only while Emacs waits or reads command input (`doc/lispref/processes.texi:2188-2250`). Intermediate status changes may coalesce, though termination is delivered exactly once (`doc/lispref/processes.texi:2252-2261`). Sentinel errors are caught, and recursive sentinel execution is prevented by temporarily clearing the sentinel; therefore a running sentinel cannot replace itself (`doc/lispref/processes.texi:2263-2288`). Replacing a not-yet-run sentinel takes immediate effect (`doc/lispref/processes.texi:2299-2307`).

### Actual use

Comint’s process filter:

- runs a transforming preoutput chain;
- inserts and marks output;
- invokes a broadcast output hook;
- carefully maintains markers and user point (`lisp/comint.el:2199-2258`).

Its redirection feature composes a temporary filter using advice primitives and removes it during cleanup, but acknowledges callback cleanup cannot be guaranteed (`lisp/comint.el:3805-3837`).

**High severity:** asynchronous extension code must handle reentrancy, arbitrary chunking, dead buffers, stale callbacks, and explicit teardown.

## 8. Package activation, loading, and unloading

Package installation, activation, and loading are distinct. Activation adds paths and evaluates autoload files; actual package code is loaded later on demand (`lisp/emacs-lisp/package.el:45-69`).

`package-activate-1` recursively activates dependencies, reloads already-loaded files when needed, loads autoloads, adds Info paths, and records activation (`lisp/emacs-lisp/package-activate.el:345-383`). Activation is session-global through `package-activated-list` (`lisp/emacs-lisp/package-activate.el:200-215`).

Autoloading places a placeholder in the function cell and replaces it on first call (`doc/lispref/loading.texi:531-603`). If an autoload-triggered load fails, definitions and `provide` operations from that attempt are rolled back so the next call can retry (`doc/lispref/loading.texi:637-650`). Ordinary load errors only terminate evaluation; rollback is specifically guaranteed for autoload-triggered loads (`doc/lispref/loading.texi:167-170`).

`load-history` records definitions, requirements, and provided features, while `function-history` preserves prior function definitions for restoration (`doc/lispref/loading.texi:1163-1246`). `unload-feature`:

- restores prior definitions/autoloads;
- removes named functions from known hooks and `auto-mode-alist`;
- unprovides features;
- cancels timers stored directly in variables defined by the library;
- refuses dependency-breaking unload unless forced (`doc/lispref/loading.texi:1248-1294`).

The implementation explicitly admits its cleanup cannot find anonymous installed functions and may miss other important state (`lisp/loadhist.el:267-324`).

### Actual resource teardown

- `recentf-unload-function` disables its global mode; mode shutdown removes hooks, saves state, hides UI, and manages its timer (`lisp/recentf.el:1382-1400`, `1510-1542`).
- Tramp explicitly removes global handlers and hooks and maintains an unload checklist (`lisp/net/tramp.el:2938-2947`, `7583-7595`).
- Flymake mode shutdown removes buffer-local hooks, cancels its timer, deletes overlays, and clears diagnostics; buffer death calls the same shutdown path (`lisp/progmodes/flymake.el:1467-1508`, `1571-1579`).

**High severity:** unloading is best effort, not transactional deactivation. Anonymous callbacks, processes, overlays, external state, modified shared registries, and resources not reachable through known variables require explicit package cleanup.

`module-load` is an especially weak direct lifecycle seam: unlike `load`, it does not update `load-history` or guard recursive loads (`doc/lispref/loading.texi:1412-1428`). Module-owned pointers require finalizers for native resources (`doc/lispref/loading.texi:1396-1405`).

## 9. Resource ownership and stale asynchronous work

Emacs has no first-class owner token linking a package to all timers, hooks, processes, overlays, keymaps, and files it creates. Packages conventionally:

- store handles in named or buffer-local variables;
- use enable/disable functions as acquisition/release pairs;
- attach buffer death and unload callbacks;
- make teardown idempotent.

Flymake additionally demonstrates generation-based callback validity. Each backend run gets a fresh token; reports bearing an old token are rejected as obsolete (`lisp/progmodes/flymake.el:1069-1105`, `1262-1276`). Its backend contract tells backends to cancel prior work to avoid obsolete reports and wasted resources (`lisp/progmodes/flymake.el:727-759`).

This is more transferable than Emacs’s unload heuristics: every asynchronous request should carry an owner/generation identity checked at publication time.

## 10. Introspection

Emacs exposes unusually broad live inspection:

- `symbol-function`, `fboundp`, and `function-alias-p` inspect callable identity and alias chains (`doc/lispref/functions.texi:1629-1671`, `803-812`).
- `symbol-value` inspects dynamic/global values, with the lexical limitation noted above.
- `advice-member-p` and `advice-mapc` enumerate named advice (`doc/lispref/functions.texi:2223-2233`).
- `symbol-file`, `load-history`, and `function-history` identify provenance and prior definitions (`doc/lispref/loading.texi:1163-1246`).
- `current-active-maps` reports keymaps that would participate in lookup (`doc/lispref/keymaps.texi:1110-1119`).
- `process-filter` and `process-sentinel` expose installed callbacks (`doc/lispref/processes.texi:1939-1941`, `2325`).
- Flymake provides commands for running, disabled, and reporting backends (`lisp/progmodes/flymake.el:1232-1251`).

Dynamically generated functions can still defeat source navigation unless they supply definition metadata (`doc/lispref/functions.texi:746-758`).

## 11. Failure and concurrency model

Failure policy is boundary-specific rather than uniform:

| Boundary | Behavior |
|---|---|
| Ordinary hook/advice/handler | Error normally propagates unless caller catches it. |
| Command pre/post hooks | Error is silenced and offending function removed. |
| Process filter/sentinel | Error caught and displayed; interrupted computation continues. |
| Flymake backend | Signaled backend error disables that backend for the buffer. |
| Autoload-triggered load | Partial function definitions/provides are rolled back. |
| Package activation | Autoload errors are demoted, after which activation bookkeeping continues (`lisp/emacs-lisp/package-activate.el:378-383`). |

**Medium severity:** extension authors cannot assume one universal isolation or retry policy.

Emacs Lisp threads share global memory. Switching is “mostly cooperative,” but correct programs are explicitly forbidden from relying on that; switches occur at explicit yields, input/process waits, mutex waits, and joins (`doc/lispref/threads.texi:7-26`). Dynamic bindings, current buffer, and match data are thread-local, while lexical closure cells are shared (`doc/lispref/threads.texi:28-42`).

Processes are locked by default to their creating thread, and only one thread waits for a given process at a time (`doc/lispref/processes.texi:2157-2174`).

**High severity:** mutable alists, symbol cells, and registries are shared state. Cooperative scheduling reduces interleavings but does not make compound read-modify-write operations atomic.

## 12. What Emacs cannot safely redefine live

1. **Calls that bypass symbolic indirection:** direct C calls and native calls without trampolines.
2. **Code copied into callers:** macro expansions, compiler macros, and inline bodies.
3. **Special forms:** not adviceable; replacing evaluator-level syntax is not a supported safe seam.
4. **Advice infrastructure primitives:** replacement may recurse or break trampoline generation.
5. **Anonymous/captured callback objects:** redefining a same-named symbol does not replace an already stored closure object.
6. **Existing state and resources:** new code does not automatically migrate buffer-local values, process protocol state, overlays, timers, or external processes.
7. **Untracked registrations:** unload scanning cannot reliably remove anonymous callbacks or arbitrary alist mutations.
8. **Directly loaded native modules:** weak provenance and lifecycle tracking make reversal unsafe.
9. **A currently executing activation:** replacement changes future lookup, not the code object already running on the stack; cleanup must tolerate overlap with old callbacks.

## 13. Transferable principles versus Emacs-specific accidents

### Transferable principles

- Put stable, inspectable indirection at every supported replacement boundary.
- Prefer symbolic registration plus stable registration IDs over anonymous callbacks.
- Distinguish notifications, veto chains, first-success handlers, wrappers, and transforms.
- Define ordering explicitly but design extensions to minimize order dependence.
- Pair every acquisition with idempotent release and owner-scoped cleanup.
- Carry generation tokens through asynchronous work and reject stale publication.
- Specify per-boundary failure, retry, and isolation behavior.
- Preserve provenance and prior definitions for inspection and rollback.
- Make redefinition coverage explicit: indirect calls, compiled calls, and foreign calls may differ.
- Treat shared registries as concurrent mutable state even under mostly cooperative scheduling.

### Emacs-specific accidents

- Separate symbol value/function cells and the global obarray.
- Naming conventions such as `-hook`, `-functions`, and `FEATURE-unload-function`.
- Buffer-local hook values using literal `t` to splice in the global hook.
- Numeric depth convention `-100..100`.
- Mutable global alists whose list position determines priority.
- File-handler precedence based on latest regexp match start.
- Symbol properties as metadata registries.
- `load-history` plus obarray scanning as an unload mechanism.
- Recursive command loops and terminal-local overriding keymaps.
- Packages being “activated” by path/autoload mutation rather than an explicit runtime instance.

## 14. Evidence-backed candidate validation for a transferable runtime

Candidate behavioral checks derived from the evidence:

1. Redefining a symbol changes future symbolic calls but not previously captured anonymous closures.
2. Advice order is deterministic across mixed depths and equal-depth additions; removal restores the latest underlying definition.
3. Normal redefinition preserves named advice, while raw cell mutation has an explicitly tested policy.
4. Handler fallback cannot recurse into itself and composes correctly with multiple handlers.
5. Normal, veto, first-success, and transforming hooks have separate tests and error policies.
6. Command-boundary cleanup runs after success, error, and cancellation.
7. Disabling/unloading an extension releases all owned timers, processes, hooks, overlays, handlers, and keymaps idempotently.
8. Reports from an obsolete async generation cannot publish state.
9. Failed activation either rolls back completely or leaves a documented inspectable degraded state.
10. Concurrent registry mutation is serialized or rejected rather than relying on cooperative scheduling.
11. Compiled and foreign call paths are tested separately from interpreter-level redefinition.

## Residual risks and confidence

- **Confidence: high** for the documented mechanisms and cited built-in usages; manuals were cross-checked against implementation.
- No runtime experiment was necessary or performed.
- Absence claims are bounded to this pinned revision.
- Physical unloading behavior of all native module/platform combinations was not traced beyond the documented lifecycle boundary.
- Package activation and unload compose imperfectly; this report does not claim `unload-feature` is a full package deactivation operation.