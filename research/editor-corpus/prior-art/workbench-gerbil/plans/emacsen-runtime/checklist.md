# Host-neutral extensible Lisp runtime roadmap

Status: M0–M10 and the approved Tuna startup/configuration refinement are completed evidence; the core decision is Go with recorded exclusions, and later extension-runtime milestones require explicit owner direction.
Historical approval: the prior Oracle hash and blanket milestone authorization applied to the superseded editor-shaped remainder. They do not authorize automatic execution of this revision.

## Goal

Determine, with small behavior-facing slices, whether Gerbil can support a live Lisp runtime for a highly configurable application. The runtime hosts a core, independently developed packages, and runtime configuration; no particular host application is assumed. GNU Emacs is an evidence source for mature extensibility semantics, not the product model or an implementation checklist.

## Scope and decision boundary

The candidate seam is a **process-wide live name**, represented by an interned Gerbil symbol, with independent function and value domains. Gerbil modules remain lexically namespaced; only designated public extension forms and operations rendezvous through this runtime namespace. Packages must prefix public live names to avoid collisions. Ordinary Gerbil `def`, imports, calls, and private implementation details remain lexical and are not assumed to become live symbol-cell operations.

The architecture has three boundaries:

1. **Live language runtime:** designated definitions, replacement, dynamic extent, source loading, stable identity, and introspection.
2. **Extension runtime:** host-neutral named actions, compiled Gerbil packages/modules, a serialized command runtime, hooks/events, documentation, and provenance.
3. **Host application:** any future buffers, files, rendering, input, sessions, requests, workspaces, or other application-specific context.

Gerbil is a **go** only if designated already-compiled callers observe replacement in every production compilation mode the project claims, deployed runtime configuration works with useful diagnostics, dynamic state restores safely, and host-neutral action dispatch remains live. It is a **no-go** if the product requires arbitrary ordinary Gerbil calls or already-expanded macros to change without explicit indirection or recompilation.

### Confirmed Tuna behavior — preserve as completed

These baseline checks are complete for the current Tuna runtime. The completed M2–M4 evidence below, rather than these two checks alone, establishes the separately compiled, optimized, deployed, and concurrency claims.

- [x] The same designated `defun` form installs and then replaces a function during one running Tuna process.
- [x] The same live name has independent value storage: initialize-only `defvar` preserves a prior value, and generalized `set!` access updates the value without replacing the function.

M1 is complete through the tracked independent development-mode fixture and local commit recorded below. Its former compiled-lookup residual risk was resolved for the supported modes by completed M2 and M3 evidence.

## Non-goals

- Reproduce Emacs's C symbol representation, flat global obarray, or every Emacs Lisp form.
- Make ordinary Gerbil `def` and direct imported calls transparently hot-redefinable.
- Make replacement alter an invocation already executing or code already produced by macro expansion.
- Build buffers, files, rendering, input decoding, keymaps, a host-specific input/render event loop, package distribution/installation, a customization user interface, or any other host-specific facility.
- Promise atomic multi-definition configuration loads, dependable arbitrary-side-effect rollback, or full unloading; adoption requires a separate owner-approved plan and Architecture Decision Record (ADR).
- Treat native module reload as equivalent to live binding replacement or adopt native reload as a supported runtime seam without a separate owner-approved plan and ADR.

## Settled roadmap decisions

1. Test an explicit process-wide live namespace keyed by interned symbols, not a compiler fork. Gerbil runtime symbols and live names are distinct from hygienic Gerbil module identifiers; package-style name prefixes provide collision discipline (`research/emacs-runtime-roadmap-audit.md`, §§1–3; `research/gerbil-emacsen-runtime-spikes.md`, §§2, 4, 8).
2. Keep extracted implementation procedures as snapshots. A separately named stable forwarding procedure may remain live, but that stronger-than-Emacs behavior must never be confused with extraction (`research/gerbil-emacsen-runtime-spikes.md`, Spike 3).
3. Put compiled lookup immediately after the minimal cell kernel. Interpreter-only success is insufficient (`research/emacs-runtime-roadmap-audit.md`, roadmap-critical finding 2 and §9).
4. Evaluate dynamic binding, cleanup, and concurrency together before extension callbacks or advice (`research/emacs-runtime-roadmap-audit.md`, roadmap-critical finding 3 and §18).
5. Prefer typed, purpose-specific action, documentation, customization, and provenance metadata. Do not add a generic property bag merely because Emacs exposes symbol property lists (`research/emacs-runtime-roadmap-audit.md`, roadmap-critical finding 1 and §§4–6).
6. Require minimal deployed repeated read/expand/eval/load. Use Gerbil's compiled package, module, dependency, and loader mechanisms directly; Tuna adds only the live registration seam needed by runtime-loaded extensions. Exact Emacs feature/autoload conventions remain evidence rather than compatibility requirements (`research/emacs-runtime-roadmap-audit.md`, roadmap-critical finding 5 and §§16–17).
7. Do not shadow or redefine existing Gerbil core bindings to copy Emacs names. Use idiomatic, non-conflicting Gerbil names and document the corresponding Emacs operation. Exact Emacs names are acceptable only when they do not collide with Gerbil semantics.
8. Keep host concepts out of the runtime. Generic context-local values remain proven but provisional until a real host establishes context identity, ownership, lifetime, and inheritance.
9. Keep Tuna runtime-library resolution separate from user configuration selection. Development uses `gerbil env`; a future installed launcher establishes the packaged runtime environment. Tuna then loads either `${XDG_CONFIG_HOME:-$HOME/.config}/tuna/config.ss`, one explicit `--config FILE`, or no config with `--no-config`. The loader never searches the working directory or mutates Gerbil's load path, and neighboring `gerbil.pkg` files do not choose the user configuration language.

### Hard-to-reverse design choice

| Design | Reversibility and evidence | Disposition |
|---|---|---|
| Process-wide symbol registry of stable per-name cells | Bounded prelude/runtime library; preserves Gerbil modules while giving config an Emacs-like rendezvous namespace. Publication is synchronized, each thread caches discovered cells, and each cell owns update synchronization. | Selected after M4 correctness and performance characterization. |
| `defun`-generated forwarding procedure caching its stable function cell | Avoids registry lookup on ordinary calls while preserving live replacement. The wrapper remains live, unlike an extracted implementation snapshot, and optimizers must preserve its mutable cell dereference. | Selected; required M2 positive path in normal and `-O` production modes. |
| Custom language/compiler rewrite of ordinary definitions and calls | Broad phase/tooling surface and long-lived compiler assumptions. | Do not pursue unless explicit registry ergonomics fail and the owner reopens scope. |

M2 and M3 now establish the supported compilation/deployment modes. A future production adoption may record the selected live-seam architecture in an Architecture Decision Record (ADR), but this evaluation roadmap does not create one automatically.

## Public test seam and validation rule

The highest useful test seam is source-level use of the designated public forms and operations from an independent caller/configuration unit: define, call/read, assign, inspect/remove, reload, and dispatch. Tests must assert returned values and diagnosed failures, not internal hash/box layout. Each spike must run outside Tuna application files in an isolated fixture directory.

M0–M10 are completed evidence. This revised roadmap grants no automatic execution authorization for M11 or later: begin a later slice only after explicit owner direction and its stated product gate. Every new slice advances through three recorded gates: (1) its acceptance behavior and stop gate pass, (2) its complete evidence record is written, and (3) the passing slice is captured according to the owner's current Git instructions. Later slices follow only the revised dependency table below, not numeric sequence, and each may be deferred or characterized as unsupported without blocking an unrelated slice.

Every result must record the exact Gerbil checkout commit and installed version, all dirty paths in the nested Gerbil checkout, the enclosing workbench checkout baseline, the sanitized runtime environment, compiler mode, tracked fixture source root and package ID, command, exit status, and observable output. The authoritative mapping establishes `gxi`, normal `gxc`, `gxc -O`, and `gxc -O -full-program-optimization` as the required initial matrix; successful `gxi` output alone is not evidence for deployment (`research/gerbil-emacsen-runtime-spikes.md`, §§3, 10). Generated compiler and runtime artifacts must remain outside both checkouts.

---

# Must-test language/runtime milestones

## M0 — Freeze the executable contract and matrix

- [x] Contract and supported-mode matrix recorded before adding behavior.

**Emacs reference behavior.** Ordinary interpreted and byte-compiled named calls normally resolve the current function cell, while extracted functions, macro expansions, explicit inlining, and some native direct calls are snapshots/direct paths. Emacs native speed 2 and speed 3 are themselves non-uniform, so “compiled” is not one behavior (`research/emacs-runtime-roadmap-audit.md`, §9; GNU Emacs 30.2 `src/eval.c:2512-2535,3031-3064`, `src/bytecode.c:608-633,740-815`, `lisp/emacs-lisp/comp.el:2805-2818,2828-2883`).

### M0 contract record

**Live namespace.** One process-wide runtime namespace is keyed by interned Gerbil symbols. A symbol can independently name a live function and live value. Gerbil lexical/module identifiers remain separate. Public live names use package-style prefixes to manage collisions; this is convention, matching Emacs practice, rather than module qualification imposed on user config.

**Live operations.** `defun` performs lifecycle-aware function installation or replacement. `defvar` initializes an absent value and preserves an existing one. Generalized `set!` through the public value accessor changes the live value. A wrapper created by `defun` performs a live call; an implementation explicitly extracted from the function cell is a snapshot. Ordinary Gerbil `def`, direct imported procedures, lexical variables, inlined calls, and already-expanded macros are outside the live contract.

**Deployment contract.** Runtime source configuration is required in development and in both supported production modes. Configuration executes in the existing process and mutates the live namespace; module reload is not the semantic foundation. Loads are sequential and may partially apply. Transactions remain unsupported here and require a separate owner-approved plan and ADR.

| Mode | Role | Live function/value lookup required | Runtime source configuration required |
|---|---|---:|---:|
| `gxi` | Development | Yes | Yes |
| normal separate `gxc` executable | Production | Yes | Yes |
| separate `gxc -O` executable | Production | Yes | Yes |
| full-program optimization | Experimental characterization only | Test and report | No current production claim |

Full-program optimization remains in the M2 matrix because it is decision-relevant, but failure does not reject Gerbil unless the owner later promotes that mode to production. A pass likewise does not add support without an explicit contract update.

**Concurrency unit.** The unit is one Gerbil process. Live defaults are shared process state. Dynamic/thread-local behavior and synchronization are intentionally unspecified until M4; M0 makes no thread-safety or atomic multi-cell guarantee.

**Explicit exclusions.** No atomic multi-definition load, rollback, unload, arbitrary ordinary-`def` replacement, update of already-running invocations, update of extracted procedures, compiled macro hot-swap, or native module/type identity replacement is promised.

**Result record required from later milestones.** Record Gerbil version/commit, mode, fixture units, command, exit status, observable output, and whether each path was a live lookup, forwarding wrapper, extracted snapshot, or unsupported direct call.

**Important non-equivalence / optimizer risk.** Gerbil is a hygienic Lisp-1 with namespaced module bindings; ordinary `def`/imports do not rendezvous through Emacs-style separate cells. Full-program optimization includes inlining, constant folding, lambda lifting, and dead-definition elimination.

**Stop gate.** Passed for contract definition. M1 may begin. Any later request to make full-program optimization a production mode, make ordinary Gerbil bindings live, or require atomic loads must first update this contract.

## M1 — Complete the minimal binding kernel

- [x] Stable identity inspection, absence, and independent removal.
- [x] Live function aliases, captured implementation snapshots, and cycle rejection.
- [x] Live value aliases and cycle rejection.
- [x] Lifecycle definition and raw mutation use separate API paths.

The lifecycle and raw paths currently perform the same validated cell update. The separation exists so later definition history and advice can attach only to lifecycle definitions.

**Emacs reference behavior.** Interned symbols have independent value, function, and property-list components. `boundp`/`fboundp` distinguish presence; `makunbound` and `fmakunbound` remove independently. Symbol-valued function cells and variable aliases remain live, whereas copying a function/value is a snapshot; alias cycles are rejected. `defalias` adds lifecycle/history/advice protocol around lower-level `fset` (`research/emacs-runtime-roadmap-audit.md`, §§1–3, 7–8; GNU Emacs 30.2 `src/data.c:714-816,889-1021`, `src/eval.c:626-720,1586-1611`).

**Exact observable acceptance target.** From a tracked independent public client in one process, using Emacs-style package-prefixed fixture names such as `workbench-emacsen-runtime-m1-target`:

- independently obtain the same interned symbol more than once and show it addresses the same identity; reject a non-symbol or uninterned symbol with a controlled condition rather than silently creating another namespace;
- keep function and value inspection independent, with **raw inspection** returning the stored tagged state without alias traversal and **followed inspection** resolving alias chains to the terminal state or a deterministic cycle condition;
- limit the M1 function cell to coherent tagged states—unbound, callable implementation, or live alias—and reject non-callable implementation payloads without corrupting the prior binding;
- rerun the completed `defun`/`defvar`/`set!` checks; distinguish a never-defined slot from a slot containing the ordinary false/empty value; remove function and value independently, with controlled unbound-function/value conditions;
- after target replacement, have a live function alias and the `defun`-generated forwarding wrapper return `new` while an explicitly extracted callable still returns `old`; make writes through a value alias visible through its target; reject direct and indirect alias cycles without corrupting bindings; and
- show with a minimal event probe that designated `defun` uses the lifecycle install entry point, while an explicitly named raw mutation bypasses lifecycle events but still enforces the same cell-state validation. Record the raw mutation policy for wrapper visibility and confirm it does not masquerade as definition lifecycle work.

**Minimal Gerbil mechanism to test.** One process-wide live-name registry record keyed only by validated interned symbols, with independent mutable function/value state and explicit tagged unbound/callable/alias variants; symbolic/hash tables or boxes; alias targets resolved by the public dispatcher with visited-set cycle detection; raw and followed inspectors; and a single public lifecycle installation operation plus separately named validated raw setters (`research/gerbil-emacsen-runtime-spikes.md`, §§4–5 and Spike 1).

**Important non-equivalence / optimizer risk.** Gerbil runtime symbols do not natively own cells, Gerbil `defalias` is syntactic, and copying a stable forwarding wrapper would remain live rather than match Emacs extraction. Keep the extracted implementation and forwarding wrapper as distinct controls. This milestone still says nothing about compiled callers.

**Stop gate.** Stop on identity ambiguity, acceptance of uninterned keys, incoherent/non-callable function state, coupled removal, undetectable absence, alias-cycle corruption, or lifecycle/raw mutation ambiguity. Do not add metadata or compiler work to mask a failed kernel.

## M2 — Compiled late-lookup decision gate

- [x] Already-compiled designated function calls, `defun`-generated forwarding calls, and global value reads pass every claimed mode.
- [x] Negative control confirms ordinary imported Gerbil calls remain bound to their original module.

**Emacs reference behavior.** Interpreted and byte-compiled named calls/reads normally retain symbol lookup. Extracted procedures, macros, compiler macros, inlining, primitive substitution, and native direct calls can bypass it; native speed-2 recursion may even keep an old implementation during recursive continuation (`research/emacs-runtime-roadmap-audit.md`, §9 and “Residual risks”).

**Exact observable acceptance target.** In isolated, tracked base/caller/replacement units, compile the caller before replacement and use package-prefixed live names. In `gxi`, normal separate compilation, and separate `-O` compilation: call returns `old`; apply the same designated `defun` replacement from another unit; the unchanged already-compiled caller returns `new`; the same-name value remains unchanged; an already-compiled public value read observes a public `set!`; an extracted implementation returns `old`; and a forwarding wrapper generated by the original `defun` before replacement returns `new`. The forwarding-wrapper result is a required positive path in both normal and `-O` production executables, not an optional control. Run the same fixture under full-program optimization and report it as experimental characterization without adding support. Negative controls report rather than conceal results for ordinary direct `def`/import calls, explicit inline calls, same-unit direct calls, recursive calls, and equivalent compiler rewrites.

**Minimal Gerbil mechanism to test.** The M1 registry/dispatcher, three small separate modules, and the researched `gxi`, normal `gxc`, `gxc -O`, and full-program optimization matrix. Ensure each designated call/read visibly dereferences mutable runtime state; do not rely on native module reload (`research/gerbil-emacsen-runtime-spikes.md`, §§3, 6 and Spikes 2–3).

**Important non-equivalence / optimizer risk.** This is the principal blocker: Gerbil can recognize known procedures, redirect or inline calls, and tree-shake definitions. A helper that looks live in `gxi` may be optimized to a direct implementation in production. Ordinary Gerbil calls are expected controls, not required successes.

**Stop gate.** If a claimed production mode returns `old` through the designated public seam, stop: redesign the seam or explicitly remove that mode from the contract and obtain owner approval before M3. If explicit mutable lookup cannot survive the required modes, Gerbil is a no-go for this role.

**M2 result.** The existing example passes `gxi`, normal separate `gxc`, and separate `gxc -O`: compiled forwarding calls and value reads observe runtime configuration, aliases remain live, and an extracted implementation remains old. A disposable three-module control passed in the same modes and confirmed that dynamically loading another module with the same ordinary `def` name does not replace an already-imported Gerbil binding; both calls return `old`. Full-program optimization is unsupported and fails while initializing the runtime expander with `Unbound variable: __eval-import`. The supported production stop gate passes; M3 may begin.

## M3 — Deployed runtime read/expand/eval/load and macro boundary

- [x] Normal and `-O` production executables each repeatedly evaluate runtime source configuration without restart.
- [x] Syntax, expansion, and runtime failures identify source in both production executables.
- [x] Newly expanded forms can change while already-compiled macro expansions stay stale in both production executables.
- [x] Full-program deployment is characterized only, with no production support claim.

**M3 result.** `lib/config.ss` owns runtime source loading through `load-config!`. Disposable normal and `-O` compiled callers each loaded one config path as `old`, paused while that same source file was rewritten, reloaded it in the same process, and returned `new`. In both compiled modes, malformed syntax reported the config path plus reader line/column detail, an unbound identifier reported its config source span, and a runtime error reported its config source span. A separate phase probe redefined a transformer from `old` to `new`: newly expanded forms returned `new`, while an already-compiled caller retained `compiled-old` in both modes. Full-program runtime expansion remains unsupported because `gerbil-load-expander!` fails with `Unbound variable: __eval-import`. The supported production stop gate passes; M4 may begin.

**Emacs reference behavior.** Emacs loads forms sequentially; an error normally leaves earlier mutations applied. A macro redefinition affects forms expanded afterward, not callers already byte/native-compiled. Positioned symbols support compiler diagnostics but are not persistent definition provenance; current definition file is mainly reconstructed from `load-history` (`research/emacs-runtime-roadmap-audit.md`, §§6, 12, 16–18; GNU Emacs 30.2 `src/eval.c:1220-1242`, `lisp/emacs-lisp/macroexp.el:216-237`, `src/lread.c:1278-1322,1697-1746`).

**Exact observable acceptance target.** Build separate normal and `-O` production executables from consistently compiled fixture units. In each executable, load tracked runtime source configuration defining a live callable as `old`, then load a changed source form defining it as `new` in the same process; public dispatch returns `new`. In both executables, separate unknown-name, syntax/expansion, and runtime-error fixtures report source path plus useful line/form location; failed multi-form loads are recorded as deliberately partial-apply because transactions are outside this roadmap. A controlled transformer change makes a newly read/expanded caller produce `new`; an already-compiled caller produces its old expansion; recompiling makes it produce `new`.

Run an equivalent full-program deployment probe only to characterize whether runtime source loading can be retained, what compiler retention flags are required, and the resulting footprint/security constraints. A full-program pass or failure neither adds production support nor changes the M0 contract.

**Minimal Gerbil mechanism to test.** Gerbil's established `read`/syntax objects, `eval`/`eval-syntax`, a dedicated expander context, compiled executable import of `:gerbil/expander`, and `gerbil-load-expander!`; route evaluated definitions through the M1 public seam and retain source locations only as needed for diagnostics (`research/gerbil-emacsen-runtime-spikes.md`, §§4–6 and Spikes 4–5).

**Important non-equivalence / optimizer risk.** Runtime evaluation in `gxi` or only one compiled mode is insufficient. Both normal and `-O` production executables must ship and initialize the expander, with footprint and security consequences. Gerbil namespaces are not one ambient Emacs namespace, and already-expanded code cannot be made live by function-cell replacement. Runtime module reload is not a substitute for evaluating designated live forms.

**Stop gate.** Stop if either normal or `-O` production mode cannot repeatedly load source, failures cannot be diagnosed, the expander boundary is unacceptable, or the macro phase contract is unstable. Full-program characterization cannot rescue a failed production mode. Do not build feature/autoload conventions yet.

## M4 — Dynamic extent, cleanup, and concurrency safety

- [x] Nested dynamic values restore on all supported exits.
- [x] Dynamic state isolation and shared live-cell visibility are characterized under the selected concurrency model.
- [x] Individual cell operations are synchronized; multi-cell atomicity is explicitly excluded.

**M4 result.** Live values support `call-with-value`, implemented with Gerbil thread-local storage plus `dynamic-wind`. The public example shows a library call observing a temporary value and the global value returning afterward. Disposable normal and `-O` compiled probes passed nested binding, normal restoration, exception restoration, continuation escape through `call/cc`, and arbitrary library-call visibility. An Emacs 30.2 reference probe confirmed that a child thread starts from the global value rather than inheriting its parent's temporary binding. Matching Gerbil probes do the same: child dynamic bindings restore independently, while global writes remain shared. Each live function or value name now owns a stable Gerbil Atom. The append-only registry synchronizes new-name publication, each thread caches discovered cells, and ordinary `defun` calls cache and dereference their function cell directly. Concurrent normal and `-O` probes observed only complete old-or-new procedures and valid whole values, including concurrent new-name publication. Median one-million-operation probes improved live function calls from 195 to 13 nanoseconds under normal `gxc`, from 129 to 8.5 nanoseconds under `gxc -O`, and from 373 to 114 nanoseconds under `gxi`; live value reads improved from 330 to 158 nanoseconds and from 167 to 116 nanoseconds in the compiled modes. Replacing an initial copy-on-write registry with append-only publication plus per-thread caching reduced creation of 10,000 function names under `gxc -O` from 1.47 seconds to 19 milliseconds. Atomic transactions across multiple names or function/value cells remain explicitly unsupported. The M4 stop gate passes; M5 may begin.

**Emacs reference behavior.** Special-variable bindings are dynamically visible down a call chain and restore during normal return, errors, and nonlocal exit. Dynamic bindings are thread-local while global cells are shared. `unwind-protect` guarantees cleanup, not rollback of arbitrary earlier mutations; multi-cell invariants need synchronization or snapshot/commit design (`research/emacs-runtime-roadmap-audit.md`, §§10, 18; GNU Emacs 30.2 `src/eval.c:1245-1439,3594-3830`, `src/data.c:1586-1626`).

**Exact observable acceptance target.** In every claimed mode, nested temporary values are visible through an arbitrary library call and restore after normal return, a raised exception, and the supported nonlocal/continuation escape. A cleanup counter has the documented exactly-once/re-entry behavior for each tested exit. Two concurrent execution units observe isolated temporary bindings and shared global replacements according to the M0 contract. Replacing one function while another unit is calling or waiting yields only documented old-or-new whole implementations, never corrupted state. Any required multi-cell invariant has a demonstrated lock/snapshot rule; otherwise the contract explicitly excludes atomic multi-cell changes.

**Minimal Gerbil mechanism to test.** Gerbil thread-local storage, `dynamic-wind` or `with-unwind-protect`, structured exceptions/continuations, plus the minimum synchronization around the M1 registry required by the selected concurrency model (`research/gerbil-emacsen-runtime-spikes.md`, §§1, 4–5 and Spike 6).

**Important non-equivalence / optimizer risk.** Gerbil parameters inherit into spawned threads, unlike Emacs special bindings, so the implementation deliberately uses thread-local storage instead. Continuation re-entry is covered for same-thread escape; cross-thread continuation behavior remains outside the contract. Atom replacement protects one stable cell, and registry publication protects discovery of one newly added name; neither creates a transaction across multiple cells.

**Stop gate.** Stop on leaked dynamic state, ambiguous continuation re-entry, data corruption, or an unspecified concurrent visibility model. Hooks/advice remain blocked until this passes.

## M5 — One minimal generic context-local value overlay (completed, provisional)

- [x] Default fallback and one lightweight context-local override pass interaction tests.

**M5 result.** `make-value-context`, `call-with-value-context`, `make-local-value!`, `local-value?`, and `remove-local-value!` provide one lightweight local-value environment without introducing buffers. The public example creates one local `message` value and then shows fallback to the unchanged global value. Emacs 30.2 reference probes established the interaction rule: a dynamic binding of an existing buffer-local value follows that buffer only, a dynamic binding of the default is visible in contexts that still use the default, and a new thread inherits its parent's current buffer but not its special-variable binding. Disposable normal and `-O` Gerbil probes matched those results with two independent local contexts plus one fallback context; passed local creation, independent writes, removal fallback, nested normal and exceptional restoration, inherited context selection, non-inherited dynamic values, and shared same-context updates; and retained the M4 thread/global contract. Median reads were 185 nanoseconds globally and 230 nanoseconds locally under normal `gxc`, and 147 nanoseconds globally and 177 nanoseconds locally under `gxc -O`. The ergonomic surface now adds hygienic `(value name)` reads, generalized `(set! (value name) expression)` assignment, `with-value-context`, and `defvar-local`. Like Emacs `defvar-local`, the first ordinary assignment in an active context creates a local value; assignment to an active dynamic binding takes precedence and does not localize. Cross-module normal and `-O` probes passed this syntax while preserving same-symbol function/value independence, fallback, removal, and automatic local recreation. These macros expand to the existing operations and add no read-time dispatch. Runtime configuration with an explicit `:tuna/lib/prelude` import also passed when the executable was launched through `gerbil env`, which supplies the local `.gerbil` package environment needed by runtime expansion; launching the binary directly against an unrelated global Gerbil path can resolve a stale or absent package prelude and is outside the local-build run contract. The M5 stop gate passes. M6 is the next possible core slice, but remains paused until an explicit owner start instruction.

**Emacs reference behavior.** Buffer-local variables select a current-buffer value or fall back to a default; removing a local binding restores fallback. Dynamic binding and localization interact with specialized unwind behavior, and current buffer is thread-local even though the same buffer's state can be shared (`research/emacs-runtime-roadmap-audit.md`, §10; GNU Emacs 30.2 `src/data.c:1594-1609,1986-2415`).

**Exact observable acceptance target.** With two lightweight context tokens: A can read its local value; B falls back to the global default; setting B does not change A or the default; removing A's local value restores fallback; nested context switching restores the outer context after normal return and failure; a documented dynamic temporary value interaction produces the same result in all claimed modes; concurrent access follows M4's isolation/sharing rule.

**Minimal Gerbil mechanism to test.** A current-context parameter, one per-context symbolic/hash table, and fallback to the existing global value cell. Use explicit public context-value operations; no buffer object or rewriting of arbitrary lexical `set!` is required (`research/gerbil-emacsen-runtime-spikes.md`, §§1, 4–5 and Spike 6).

**Important non-equivalence / optimizer risk.** This is a generic execution-context overlay, not a buffer model, Emacs's buffer C representation, or automatic bare-identifier localization. `(value name)` is an explicit hygienic marker that preserves Gerbil's lexical namespace and the separate live function/value domains. Dynamic assignment takes precedence over automatic localization, matching the observed Emacs rule. The public name `defvar-local` is provisional because the runtime does not yet define what a context means.

**Disposition.** Preserve M5 as completed feasibility evidence, but do not deepen or require context-local values for the core go/no-go decision. A future host must first establish context identity, ownership, lifetime, sharing, and inheritance; that context could represent a request, session, workspace, job, window, or another host concept.

**Stop gate.** Stop if fallback, removal, unwind restoration, or concurrent ownership is ambiguous. Do not introduce buffers, sessions, request scopes, or other host lifecycle policy in this runtime evaluation.

## M6 — Host-neutral named actions and public dispatch

- [x] One live action supports discovery, direct programmatic invocation, and host-mediated invocation.

**Runtime purpose.** A highly configurable application needs stable public operations that packages and configuration can discover and invoke without assuming an editor, terminal, graphical interface, request server, or other host. An action is a designated live function plus typed invocation metadata; ordinary private Gerbil procedures remain lexical.

**Emacs evidence.** Emacs commands demonstrate the useful distinction between direct calls with explicit arguments and name-backed dispatch that derives arguments from current host state. Name-backed dispatch follows replacement while a stored closure is captured (`research/emacs-runtime-roadmap-audit.md`, §11; GNU Emacs 30.2 `src/eval.c:535-552,2195-2303`, `src/callint.c:253-430`). The runtime adopts that distinction without adopting Emacs interactive specifications.

**Exact observable acceptance target.** Public discovery reports whether a live name is an action and exposes its current host-invocation descriptor. A programmatic call receives explicit arguments. Host-mediated dispatch passes an opaque fake host context to a pure argument-acquisition procedure, then invokes through the M1 live seam. Lifecycle replacement changes both behavior and host-invocation metadata for subsequent name-backed dispatch without rebuilding the dispatcher. A captured implementation and captured descriptor remain old. Discovery and invocation agree during replacement in every supported mode.

**Minimal Gerbil mechanism to test.** A small typed action-definition record or separately named action-metadata slot, one lifecycle-aware install operation, and dispatch through the proven live function cell. Keep action metadata separate from generic properties, documentation, and provenance.

**Non-goals.** No minibuffer, prefix arguments, keyboard events, menus, keymaps, command history, rendering, input decoding, or real event loop. Host context is opaque to the runtime.

**Stop gate.** Stop if discovery and invocation can disagree after lifecycle replacement, if dispatch bypasses the M2 live seam, or if the design requires a host-specific concept. Passing M6 completes the core Gerbil suitability evidence.

**M6 result.** `defaction` installs a live function plus a host-invocation descriptor and a pure opaque-context-to-arguments procedure. `action-bound?`, `action-host-descriptor`, `invoke-action`, and `invoke-action-with-context` provide discovery, direct invocation, and host-mediated invocation without interpreting host state. A dedicated stable action cell publishes body, descriptor, and acquirer as one immutable generation; concurrent replacement probes observed only matched old/old or new/new body/acquirer results. Plain `defun`, raw function mutation, and function removal clear action status; function aliases carry a corresponding live action alias. Disposable cross-module `gxi`, normal `gxc`, and `gxc -O` probes passed replacement, name-backed lexical calls, programmatic and host-mediated invocation, alias following, captured old implementation/descriptor behavior, plain-function clearing, and concurrent coherence. Separate normal and `-O` executables passed runtime-source `defaction` replacement when executed against their compiled package environments. Invalid acquired arguments produce a controlled error. An identical 50-million-call before/after benchmark found no material regression in ordinary `defun` calls: approximately 13.1 versus 13.5 nanoseconds under normal `gxc`, and 9.0 versus 8.5 nanoseconds under `gxc -O`; programmatic action dispatch measured approximately 142 and 101 nanoseconds respectively in a separate 20-million-call probe. The installed runtime still reports symmetric multiprocessing disabled, so true multicore contention remains unmeasured.

## Core go/no-go review

**Decision: Go, with the existing deployment exclusions.** Explicit live calls and reads pass `gxi`, normal `gxc`, and `gxc -O`; deployed runtime configuration and macro boundaries are acceptable when the executable uses its compiled package environment; dynamic restoration is safe; and host-neutral action dispatch remains live and generation-coherent. Full-program optimization remains unsupported for runtime source expansion. Loads remain sequential and partially applied, multi-cell transactions and unload remain unsupported, already-expanded macros and ordinary lexical Gerbil calls remain snapshots/direct paths, and true multicore behavior remains a residual risk. These exclusions do not block the host-neutral extension runtime.

M5 context-local values are completed feasibility evidence but are not a core go/no-go dependency.

### Approved Tuna startup/configuration refinement — completed

- [x] Tuna has one optional XDG user config, one explicit command-line override, and one no-config recovery path.
- [x] External config explicitly imports the Tuna prelude independently of its directory and nearby package metadata.
- [x] Runtime package resolution remains a launcher/deployment responsibility rather than hidden config-loader path mutation.

**Result.** The executable and package are named `tuna`. With no option, startup selects `${XDG_CONFIG_HOME:-$HOME/.config}/tuna/config.ss` and silently continues when it is absent. `--config FILE` replaces the default and requires an existing file; `--no-config` suppresses loading; conflicting, incomplete, repeated, or unknown argument shapes fail with one controlled usage contract. `load-config!` normalizes the selected existing path, begins in ordinary Gerbil, reads syntax with path and line/column diagnostics, and evaluates forms sequentially so the config's explicit `:tuna/lib/prelude` import governs later forms and a runtime failure leaves prior forms applied and later forms untouched. It does not inspect or modify Gerbil's load path and does not derive language semantics from the config directory or a neighboring `gerbil.pkg`. Fresh development builds, launcher-provided direct execution, external XDG files without package metadata, a hostile neighboring package prelude, missing-default/no-config recovery, explicit override/error cases, sequential partial application, and normal plus `gxc -O` external-config executables passed. Development runs through `gerbil env tuna`; production packaging must establish the compiled Tuna runtime environment separately.

---

# Remaining host-neutral extension-runtime milestones

These are capabilities for a live package/configuration ecosystem, not a sequence of Emacs features to clone. Begin each only for an approved runtime use case, implement one minimal vertical behavior, and stop at the stated boundary. Numeric order expresses the current recommended priority; the dependency table controls execution.

## M7 — Gerbil-native compiled package loading

- [x] External config imports one independently namespaced compiled Tuna package and reconfigures its live extension points.
- [x] Ordinary runtime code loads the same compiled entry module through Gerbil's loader without duplicate initialization.

**Runtime purpose.** Tuna packages are ordinary compiled Gerbil packages containing one or more modules. Their package or source declaration explicitly selects the Tuna prelude when they publish `defun`, `defvar`, or `defaction` extension points. Private implementation remains ordinary lexical Gerbil. `config.ss` is the normally dynamic source layer and uses ordinary `import` to load compiled package entry modules and bind their exported configuration API.

**Acceptance target.** Build an independent dummy package beneath `packages/` with its own `gerbil.pkg`, build script, namespace, and canonical entry module. From external `config.ss`, import that compiled module, call an exported ordinary procedure, update one live value, replace one live function, and show an already-compiled package caller observes both changes. Invoke a package action. Then call `load-module` for the same entry module and show Gerbil suppresses duplicate initialization. Validate source execution, normal `gxc`, and `gxc -O` without evaluating package source at runtime.

**Minimal mechanism.** Gerbil `gerbil.pkg`, `:std/build-script`, compiled module imports, runtime `load-module`, and the existing Tuna prelude/live seams. Do not add a Tuna feature/provide layer or package loader wrapper.

**Stop gate.** Stop if dynamic config imports cannot bind a compiled package's exports for later forms, if compiled callers bypass required live definitions, or if runtime loading requires package source evaluation. Do not infer unload, source reload, package installation, version solving, or post-load callback semantics.

**M7 result.** `packages/dummy/` is an independently namespaced `tuna-dummy` Gerbil package whose `gerbil.pkg` selects `:tuna/lib/prelude`; it has its own build script and compiled `plugin` entry module. The package exposes a live value, function, and action plus an ordinary compiled caller of the live function. The tracked `config.ss` explicitly imports `:tuna/lib/prelude` and `:tuna-dummy/plugin`, calls the compiled API, changes the live value, replaces the live function, and shows the unchanged compiled caller observing `dummy before`, `dummy configured value`, and `dummy redefined function` in sequence; host-mediated action invocation also passes. Calling `load-module "tuna-dummy/plugin"` after import returns the already-loaded compiled module, and the package initialization count remains one. The Tuna build excludes the dummy package; the package's independent build installs its compiled module into Tuna's development environment, and both builds pass. Disposable source, normal `gxc`, and `gxc -O` fixtures pass config import, runtime module loading, duplicate suppression, action registration, and compiled-caller live replacement. No Tuna feature registry, source-package evaluator, package manager, deferred loader, unload, or reload contract was added.

## M8 — Long-lived serialized command runtime

- [x] Tuna remains alive around one bounded command lane that executes current named actions one at a time and survives ordinary command failure.

**Runtime purpose.** Like Emacs's command loop, Tuna needs one durable recovery boundary around state-changing commands. Unlike Emacs, Tuna should not serialize all Lisp execution: concurrent producers and unrelated I/O may run in other Gerbil threads, while one runtime-owned worker serializes the commands that may mutate authoritative application state.

**Acceptance target.** Construct an instance-owned runtime with a positive bounded capacity; start it exactly once; submit explicit-argument and opaque-context commands from concurrent producers; resolve each action when dequeued so queued work observes live replacement; never overlap command handlers; complete every accepted command exactly once with its result or original exception; reject overload without silently dropping accepted work; continue after an ordinary command failure; stop accepting, drain accepted commands, join the worker, and reject later submissions. Admission transfers payload ownership until completion; producers must not mutate queued arguments or contexts. `main` loads configuration, starts this runtime, and waits rather than returning after a demonstration.

**Minimal mechanism.** One named Gerbil thread, one bounded `:std/sync/channel`, one `:std/sync/completion` per accepted command, and the existing M6 action dispatch. Use immediate bounded admission for the first slice. Keep application state opaque and owner-confined by contract; do not impose immutable transitions, rollback, or a process-global singleton.

**Stop gate.** Stop if action resolution occurs before dequeue, failures kill the worker, accepted work can disappear, queue bounds are bypassed, shutdown races admit work after stopping, or production execution requires HTTP or source-package evaluation. Long-running action offload and cooperative cancellation remain unsupported.

**M8 result.** `lib/runtime.ss` adds an instance-owned `CommandRuntime` with a positive bounded `:std/sync/channel`, one retained `tuna-command-runtime` worker, and one `:std/sync/completion` per accepted request. Explicit-argument and opaque-context submissions return `accepted`, `full`, or `not-running`; accepted requests store only the action name and payload, so M6 resolution occurs on the worker at dequeue. Action exceptions complete the individual request with the original exception and the worker continues. Stop changes admission state under the same mutex used by submission, closes the inbox, drains accepted work, and joins to `stopped`. A finite-timeout wait keeps an intentionally idle standalone runtime alive without triggering Gambit's deadlock detector. `main.ss` now loads configuration, starts one runtime, and waits instead of executing demonstrations and returning. The tracked unit fixture passes bounded overload, queued live replacement, context dispatch, failure recovery, drain/reject shutdown, and four concurrent producers with per-producer ordering and no handler overlap. The reproducible `test/run-command-runtime-matrix.sh` runs the full behavior suite—not a reduced smoke test—in sanitized source `gxi`, normal `gxc`, and `gxc -O` executable environments; all pass with checkout `4531c21b90fa6ee04f374af905ae3ddb9d89d590`, runtime `Gerbil v0.19-dev-31-g4a4d1a30 on Gambit v4.9.7-6-g64f4d369`, and active tools under `/opt/gerbil/bin`. `gerbil env tuna --no-config` remains alive without deadlock, and the configured dummy package loads before the runtime starts. A disposable 50,000-command batch probe over three runs measured median throughput of approximately 405,000 commands/second under normal `gxc` and 655,000 commands/second under `gxc -O`; this is a synthetic no-op throughput characterization on the installed SMP-disabled runtime, not an end-to-end latency guarantee. No application state model, publication channel, HTTP behavior, host input mapping, cancellation, priority, rollback, or process-global singleton was added.

**M8 evidence record.** From workbench baseline `6b22b3508a9675868aab9056b65fd88ceaa056b1` and Tuna baseline `3552a1e6ff7d067a15ddb5d496420a6446186ab6`, `tuna/test/run-command-runtime-matrix.sh` exited 0. It recorded Gerbil checkout `4531c21b90fa6ee04f374af905ae3ddb9d89d590`, active runtime `Gerbil v0.19-dev-31-g4a4d1a30 on Gambit v4.9.7-6-g64f4d369`, `/opt/gerbil/bin/gxi`, and `/opt/gerbil/bin/gxc`; the only dirty Gerbil paths before and after were unstaged `src/gambit/lib/_kernel.c`, `_module.c`, and `_num.c`, with no staged Gerbil paths. The tracked fixtures are `:tuna/test/command-runtime-test` and `:tuna/test/command-runtime-suite-main`. Every mode used `env -i`, isolated temporary `HOME`, `TMPDIR`, and `GERBIL_PATH`; source expansion and compilation used only the absolute Tuna source root as `GERBIL_LOADPATH`, while produced executables ran with an empty load path. Observable output was `gxi: pass`, `gxc: pass`, `gxc -O: pass`, and `worktree status: unchanged`; byte-for-byte before/after porcelain snapshots for both the enclosing workbench and Tuna checkout matched. Separately, `gerbil build` and `gerbil test test/command-runtime-test.ss` exited 0; a two-second `gerbil env tuna --no-config` probe timed out as intended after logging `command runtime started` and no deadlock, and the equivalent configured probe loaded the dummy package before logging runtime start.

## M9 — Immutable application state and latest-state publication

- [x] One runtime-owned immutable application value advances by pure live transitions and publishes coherent revisioned snapshots through bounded, coalesced invalidation channels.

**Runtime purpose.** A generic extensible program needs one authoritative application value whose successful changes are serialized, rollback cleanly before commit, and can be observed without exposing mutable authority or blocking the command owner. Tuna defines the ownership and publication protocol, not the application's state shape.

**Acceptance target.** An application supplies an opaque initial value and live transitions returning explicit changed or unchanged outcomes. The command owner resolves transitions at dequeue, retains the exact prior revision/value on unchanged results and exceptions, installs one coherent new revision/value on change, notifies each subscriber without blocking, coalesces redundant wakeups, and lets consumers reread the latest snapshot. Direct transition invocation can calculate an outcome but cannot install it. Runtime instances using the same transition definitions keep independent roots.

**Minimal mechanism.** One immutable-by-contract root containing revision and opaque value, the existing bounded command lane, one dedicated live transition metadata domain, one private mutex for coherent root/subscriber operations, and one capacity-one channel per subscriber. This is latest-state invalidation, not history, undo, a durable event log, or a database transaction log.

**Stop gate.** Stop if ordinary action semantics change, state authority becomes ambient or process-global, failed transitions can install a candidate, readers can observe mixed roots, subscribers can block commands, or Tuna must inspect/deep-copy application values. Do not introduce HTTP, Server-Sent Events, Datastar, browser/editor/session concepts, rendering, persistent collections, effects, persistence, event sourcing, or distributed brokers.

**M9 result.** `deftransition` publishes a live state-transition implementation independently from ordinary action metadata while retaining the existing live function wrapper. `state-changed` and `state-unchanged` make commit intent explicit. `make-state-command-runtime` owns one `(revision, opaque-value)` root; `command-runtime-submit-transition!` resolves the current transition on the worker at dequeue, installs only changed outcomes, and completes unchanged, failed, or invalid outcomes without changing the root. `command-runtime-snapshot` returns one coherent revision/value pair. `command-runtime-subscribe-state!` atomically registers a subscriber and returns the current pair; each opaque `StateSubscription` uses one capacity-one channel, coalesces full-channel invalidations through `channel-try-put`, and closes deterministically on unsubscribe or runtime shutdown after draining. Installation is owner-only and ordered before invalidation and completion. Plain functions/actions and removal clear transition status; function aliases carry a corresponding live transition alias.

The dedicated test fixture passes constructor and boundary validation, changed/unchanged/failure rollback-by-discard, invalid outcomes, direct non-installing invocation, queued live replacement, alias following, two-runtime isolation, ordinary-definition clearing, coherent concurrent reads, coalescing, subscribe/install races, drain ordering, and subscription closure under source `gxi`, normal `gxc`, and `gxc -O`. The reusable pre-production spike and evidence remain at `research/fixtures/tuna-immutable-state-spike/` and `research/tuna-immutable-state-spike-results.md`. A disposable 50,000-transition benchmark against the production implementation, with one permanently full subscriber, measured medians of approximately 323,000 commands/second under normal `gxc` and 591,000 under `gxc -O`; application transition cost remains host-dependent. Gerbil v19 cannot enforce transitive immutability and has no installed supported persistent map, so applications own immutable representation, alias discipline, state composition, effects, persistence, history, and migration. Tuna does not retain old roots or infer equality.

## M10 — Hooks and events

- [x] One sequential event supports deterministic named and explicitly captured listeners.

**Runtime purpose.** Packages need a low-coupling way to cooperate around application-defined extension events after M8 establishes meaningful command lifecycle boundaries.

**Acceptance target.** Add, remove, and run listeners in deterministic order. A live-name listener observes later replacement; an explicitly captured procedure remains old. Duplicate identity, anonymous removal, mutation during dispatch, and failure policy are documented.

**Minimal mechanism.** A typed event/listener collection whose name-backed entries dispatch through M1. Do not model hooks as arbitrary variable contents merely because Emacs does.

**Stop gate.** Stop until listener identity, ordering, removal, mutation-during-run, and failure behavior are deterministic. Context-local events wait for an approved host-context need.

**M10 result.** `lib/event.ss` adds a typed `Event` with `make-event`, `event-add!`, `event-remove!`, and `event-run!`; Tuna defines no process-global application events and does not automatically attach events to state commits. Event names and registration identities are validated interned symbols. Registrations execute sequentially in insertion order. A symbol target resolves through the current live function cell at dispatch, while a procedure target remains captured. Duplicate identities are rejected; removal returns whether an identity existed. Dispatch snapshots the immutable registration list and releases the event mutex before invoking extension code, so additions and removals during a run affect the next run without deadlocking. The first listener exception stops later listeners and propagates to the emitter. Event invocations themselves are not globally serialized; callers that need cross-invocation ordering use the existing command owner.

The dedicated event suite passes validation, live-named versus captured behavior, deterministic order, duplicate rejection, idempotent removal, mutation-during-dispatch snapshot semantics, and fail-fast propagation under source `gxi`, normal `gxc`, and `gxc -O`. A disposable one-million-dispatch benchmark with one named no-op listener measured medians of approximately 4.53 million dispatches/second under normal `gxc` and 5.15 million under `gxc -O`. No priorities, local events, asynchronous listener execution, wildcard events, automatic lifecycle events, failure containment, or audit history were added.

## M11 — Documentation and discovery

- [x] Current action/function and value documentation is discoverable through typed public interfaces.

**Runtime purpose.** A configurable runtime must explain its public extension points to people and tooling without reconstructing source from optimized procedures.

**Acceptance target.** Discovery distinguishes actions, live functions, and live values; same-name function and value documentation coexist independently; lifecycle replacement updates definition-owned documentation according to one explicit policy; initialize-only value definition does not overwrite a user value merely to update documentation. Captured old definition objects may retain old documentation while name-based lookup reports the current definition.

**Minimal mechanism.** Typed documentation fields associated with lifecycle definition records. Add an override mechanism only for a demonstrated use case.

**Stop gate.** Stop if documentation resets runtime state, conflates function and value identity, or requires a generic property bag.

**M11 result.** `defun`, `defaction`, `deftransition`, `defvar`, and `defvar-local` accept one explicit `doc:` literal in a fixed position; a first body string remains an ordinary result expression. `callable-descriptor` returns an immutable-by-interface snapshot with kind `function`, `action`, or `state-transition` and optional documentation, while `value-descriptor` returns an independent value snapshot. Public descriptors are opaque zero-slot tokens, so generic Gerbil slot mutation cannot corrupt a snapshot; copied details live in private weak-key tables, and accessors return fresh documentation-string copies. Separate callable/value current-descriptor tables are keyed by existing stable root cells and guarded by `bindings-mutex`, so aliases follow target documentation without a second alias model and the same symbol retains independent callable/value metadata. No descriptor Atom, name enumeration, generic property bag, source reconstruction, provenance, or configuration schema was added.

Lifecycle replacement owns current documentation. Omission clears prior definition documentation; raw function mutation installs an undocumented plain-function descriptor; raw value assignment preserves value documentation. `defvar` updates documentation even when initialize-only semantics preserve a user-assigned value. Global removal clears the corresponding current descriptor, while dynamic or context-local value removal preserves global definition documentation. Captured descriptors remain old immutable snapshots. Runtime configuration retains sequential partial application, and compiled modules retain literal documentation without source files.

The dedicated documentation suite covers macro syntax, body-string preservation, typed boundaries, all three callable kinds, same-name domain independence, replacement and captured snapshots, slot/string/input-mutation isolation, raw mutation, initialize-only values, live aliases, global versus dynamic/local removal, concurrent complete-descriptor publication, value-alias/removal linearization, compiled definitions, runtime configuration, partial failure, and rejected nonliteral/misplaced/repeated clauses. It passes with all existing suites under source `gxi`, normal `gxc`, and `gxc -O`. The ordinary 50-million-call benchmark preserves the existing hot path: final interleaved seven-run medians changed from approximately 22.38 to 22.97 nanoseconds under normal `gxc` (2.6%) and from 8.44 to 8.45 nanoseconds under `gxc -O` (0.2%); generated `function-cell-ref` code remains identical and no metadata operation was added to invocation or value reads. True multicore contention remains unmeasured because the installed runtime has symmetric multiprocessing disabled.

## M12 — Source and load provenance

- [ ] Current definition origin and global successful-load history are queryable without claiming universal source reconstruction or rollback.

**Runtime purpose.** In a live system, users and tooling must be able to ask which package or configuration currently owns a definition and which load changed it.

**Acceptance target.** Syntax/runtime errors retain occurrence locations. Lifecycle definitions can report their current source/load unit. Successful and failed loads are distinguishable. Raw mutation follows a separately documented provenance policy. Prior-function history, if adopted, is bounded and separate from global load history. Unknown source is reported honestly.

**Minimal mechanism.** Existing syntax-object locations for diagnostics, typed current-definition provenance, and a separate load ledger for recognized lifecycle operations.

**Stop gate.** Stop if provenance claims to observe arbitrary side effects, fabricates exact source positions, or implies unload/rollback.

## M13 — Configuration schema and validated assignment

- [ ] If a real configuration tool or package requires it, one live value supports typed validation and an explicit policy-aware setter distinct from ordinary assignment.

**Runtime purpose.** Generic applications may need discoverable configuration schemas and safe external configuration without adopting Emacs Customize or a particular user interface.

**Acceptance target.** A schema can describe and validate one value. Policy-aware assignment validates before mutation and can invoke a typed setter; rejection preserves the old value. Ordinary `(set! (value name) expression)` retains its direct-assignment contract. Function metadata for the same live name is unaffected.

**Minimal mechanism.** A typed value descriptor layered over the existing cell. No customization interface, widget system, or universal serialization format.

**Stop gate.** Defer this entire milestone until a concrete configuration consumer exists. Stop if ordinary assignment silently acquires validation or side effects.

## M14 — Generic execution contexts (deferred)

- [ ] Only after a host establishes a concrete context abstraction, decide whether M5 should be retained, renamed, generalized, or removed.

**Required host decision.** Define context identity, ownership, lifetime, sharing, inheritance, and cleanup. Examples may include requests, sessions, workspaces, jobs, windows, or evaluation environments, but the runtime chooses none in advance.

**Acceptance target.** Revalidate M5 fallback, dynamic interaction, restoration, and concurrency against the approved host semantics. Replace provisional terminology such as `defvar-local` if it does not communicate the chosen abstraction.

**Stop gate.** Do not begin from hypothetical reuse alone. No host context means no additional context-local runtime work.

## M15 — Advice or behavior wrapping (deferred)

- [ ] Only after hooks, ordinary replacement, and host dispatch prove insufficient, one named around-wrapper survives lifecycle-aware replacement of the inner action.

**Runtime purpose.** Advice can let a package wrap behavior it does not own, but it substantially increases reasoning and lifecycle complexity.

**Acceptance target.** Add and remove one identifiable wrapper; lifecycle replacement updates the inner implementation while retaining the wrapper; raw mutation follows a separately documented preserve/bypass rule; direct lexical calls remain explicitly unaffected.

**Stop gate.** Require a concrete package use case. Do not add before/before-while/filter families, anonymous-wrapper management, or universal interception.

## M16 — Generic symbol properties (deferred, likely unnecessary)

- [ ] Add an open-ended property facility only when typed action, documentation, configuration, and provenance metadata cannot satisfy an approved package need.

**Runtime purpose.** Open metadata can aid unforeseen package cooperation, but it can also become an untyped catch-all that obscures lifecycle ownership.

**Acceptance target.** If approved, distinguish absence from present-with-false, preserve independence from function/value replacement, and define synchronization. Do not migrate typed runtime metadata into the property facility merely to exercise it.

**Stop gate.** A generic desire for Emacs compatibility is insufficient justification.

## M17 — Characterize unsupported lifecycle boundaries

- [ ] Characterize unload, multi-definition configuration transactions, and native module reload separately; keep all three unsupported unless separately approved.

**Acceptance target.** Report which recognized lifecycle registrations a best-effort unload could reverse and which arbitrary effects remain; demonstrate that ordinary failed loads remain sequential and partially applied; distinguish explicit live-registry replacement from retained native procedures and type identities. Characterization does not create a public capability.

**Stop gate.** Any adoption of unload, transactions, or native reload requires a separate owner-approved plan and Architecture Decision Record (ADR).

## Explicit host-layer exclusions

The following are not runtime milestones:

- buffers and file abstractions;
- rendering and display trees;
- keyboard, pointer, or other input decoding;
- keymaps, command remapping, menus, and host-specific input/render event loops;
- windows, sessions, requests, or workspaces before a host defines them;
- package distribution, installation, repositories, and version solving.

A future host package may map its own inputs and contexts onto live actions and values without changing the host-neutral runtime contract.

## Revised dependency order

| Slice | Depends on | Deliverable |
|---|---|---|
| M6 host-neutral actions | M1 + M2 + M3 + M4 | Discovery, programmatic invocation, opaque-context invocation, and replacement fixture |
| Core go/no-go | M6 | Recorded runtime suitability decision and exclusions |
| M7 compiled package loading | Core go + M2 + M3 | Independent compiled package, config import, runtime load, and live-replacement fixture |
| M8 command runtime | Core go + M4 + M6 | Bounded serialized dispatch, completion, recovery, and shutdown fixture |
| M9 immutable state publication | M8 + approved immutable-root contract | Pure transition commit plus coherent snapshot and coalesced invalidation fixture |
| M10 hooks/events | Core go + M1 + M4 + M8 | Deterministic named-vs-captured listener fixture |
| M11 docs/discovery | Core go + M1 + M6 | Typed current-definition documentation fixture |
| M12 provenance | Core go + M1 + M3 | Current-origin and global-load-history fixture |
| M13 configuration schema | Core go + M1 + M11 + approved consumer | Validation/direct-assignment separation fixture |
| M14 contexts | M4 + approved host context | Host-semantic revalidation or explicit removal decision for M5 |
| M15 advice | Core go + M1 + M2 + M6 + concrete need | One named around-wrapper fixture |
| M16 properties | Core go + demonstrated metadata gap | Narrow property fixture or explicit rejection |
| M17 unload characterization | Core go + M7 + M10 + M12 | Residual-effect report; remains unsupported |
| M17 transaction characterization | Core go + M3 + M4 + M12 | Partial-load/declared-cell boundary report; remains unsupported |
| M17 native-reload characterization | Core go + M2 + M3 | Live-dispatch/native-identity comparison; remains unsupported |

## Evidence-backed validation

Accept evidence only from tracked independent fixture sources outside Tuna application files. Use package-prefixed live names and unique, resolvable package-qualified fixture module IDs. Every new fixture uses a verified absolute source root whose directory layout mirrors its package ID, for example `src/workbench/live/runtime/m6/kernel.ss` for `:workbench/live/runtime/m6/kernel`. Historical completed fixtures may retain their original `workbench/emacsen/runtime` IDs. In the current v19-staging environment, `GERBIL_LOADPATH` entries precede `$GERBIL_PATH/lib` and the installed library. The source root must therefore be the sole explicit `GERBIL_LOADPATH` entry for `gxi` source execution and compilation, while produced executables must run with an empty `GERBIL_LOADPATH` so runtime expansion reuses the compiled package modules rather than loading a second source instance. Runtime configuration source is supplied by its explicit path. The installed library remains an intentional dependency controlled by exact version attestation and a fixture-package collision check (`research/gerbil-hermetic-runtime-matrix.md`).

Before compilation, record the current `./gerbil` v19-staging commit, active `gxi`/`gxc` paths, and sanitized `gerbil --version`; reject unavailable tools, non-v19 tools, or staged Gerbil source changes. The source checkout and active build identity may differ while v19-staging advances, so evidence records both rather than imposing a stale fixed commit pair. Tuna validation must not rebuild or install Gerbil. Also snapshot the enclosing workbench checkout so unrelated dirt is not mistaken for milestone changes.

The fixture owner adapts only the tracked fixture path, unique package ID, library-unit list, and main filename in this template. Each unit must declare the matching package. The shell must retain `set -eu` (or a demonstrably equivalent fail-fast runner):

```sh
set -eu

workbench_checkout=/home/jay/Code/workbench-gerbil
gerbil_checkout="$workbench_checkout/gerbil"
gxi=$(command -v gxi)
gxc=$(command -v gxc)

fixture=/absolute/path/to/tracked-independent-fixture
fixture_source_root="$fixture/src"
fixture_package=workbench/live/runtime/milestone
units='kernel.ss base.ss caller.ss replacement.ss'
main_unit=main.ss
module_root="$fixture_source_root/$fixture_package"
main="$module_root/$main_unit"

run_root=$(mktemp -d /tmp/workbench-live-runtime.XXXXXX)
trap 'rm -rf "$run_root"' EXIT HUP INT TERM
mkdir -p \
  "$run_root/attestation/env/lib" \
  "$run_root/attestation/home" \
  "$run_root/attestation/tmp"

# Record the current v19-staging source and active build identities without
# rebuilding or installing Gerbil as part of Tuna validation.
actual_commit=$(git -C "$gerbil_checkout" rev-parse HEAD)
actual_version=$(env -i \
  HOME="$run_root/attestation/home" \
  TMPDIR="$run_root/attestation/tmp" \
  PATH=/usr/bin:/bin \
  GERBIL_PATH="$run_root/attestation/env" \
  GERBIL_LOADPATH= \
  "$gxi" -v 2>&1)

case "$actual_version" in
  'Gerbil v0.19-'*) ;;
  *)
    printf '%s\n' 'Gerbil v19 required' "actual: $actual_version" >&2
    exit 64
    ;;
esac

mkdir -p "$run_root/attestation"
printf '%s\n' "$actual_commit" \
  >"$run_root/attestation/gerbil-commit.txt"
printf '%s\n' "$actual_version" \
  >"$run_root/attestation/installed-version.txt"
git -C "$gerbil_checkout" status \
  --porcelain=v1 --untracked-files=all \
  >"$run_root/attestation/gerbil-dirty-paths.txt"
git -C "$gerbil_checkout" diff --name-only \
  >"$run_root/attestation/gerbil-unstaged-paths.txt"
git -C "$gerbil_checkout" diff --cached --name-only \
  >"$run_root/attestation/gerbil-staged-paths.txt"
git -C "$workbench_checkout" status \
  --porcelain=v1 --untracked-files=all \
  >"$run_root/attestation/workbench-dirty-paths-before.txt"

test ! -s "$run_root/attestation/gerbil-staged-paths.txt" || {
  echo 'Gerbil checkout has staged paths; refusing attestation' >&2
  exit 65
}

# Verify the one controlled source root and its package-qualified layout.
case "$fixture_source_root" in
  /*) ;;
  *) echo 'fixture source root must be absolute' >&2; exit 66 ;;
esac
test -d "$module_root" || {
  echo "missing package directory: $module_root" >&2
  exit 66
}
for unit in $units "$main_unit"; do
  source_file="$module_root/$unit"
  test -f "$source_file" || {
    echo "missing fixture unit: $source_file" >&2
    exit 66
  }
  grep -F "package: $fixture_package" "$source_file" >/dev/null || {
    echo "fixture package mismatch: $source_file" >&2
    exit 66
  }
done
for mode in gxi normal opt fpo; do
  mkdir -p \
    "$run_root/$mode/env/lib" \
    "$run_root/$mode/bin" \
    "$run_root/$mode/home" \
    "$run_root/$mode/tmp"
done

# Every invocation is sanitized and receives the matching mode's GERBIL_PATH.
# Source execution/compilation receives the verified source root; produced
# executables use only compiled package modules plus explicit config paths.
mode_env() {
  mode=$1
  shift
  env -i \
    HOME="$run_root/$mode/home" \
    TMPDIR="$run_root/$mode/tmp" \
    PATH=/usr/bin:/bin \
    GERBIL_PATH="$run_root/$mode/env" \
    GERBIL_LOADPATH="$fixture_source_root" \
    "$@"
}

run_mode_env() {
  mode=$1
  shift
  env -i \
    HOME="$run_root/$mode/home" \
    TMPDIR="$run_root/$mode/tmp" \
    PATH=/usr/bin:/bin \
    GERBIL_PATH="$run_root/$mode/env" \
    GERBIL_LOADPATH= \
    "$@"
}

# Development: package-qualified imports resolve from GERBIL_LOADPATH, never ~/.gerbil.
mode_env gxi "$gxi" "$main"

# Normal production.
for unit in $units; do
  mode_env normal "$gxc" \
    -d "$run_root/normal/env/lib" \
    "$module_root/$unit"
done
mode_env normal "$gxc" \
  -d "$run_root/normal/env/lib" \
  -exe -o "$run_root/normal/bin/run" \
  "$main"
run_mode_env normal "$run_root/normal/bin/run"

# Optimized production: every compiled unit and the final combination receive -O.
for unit in $units; do
  mode_env opt "$gxc" \
    -O -d "$run_root/opt/env/lib" \
    "$module_root/$unit"
done
mode_env opt "$gxc" \
  -O -d "$run_root/opt/env/lib" \
  -exe -o "$run_root/opt/bin/run" \
  "$main"
run_mode_env opt "$run_root/opt/bin/run"

# Experimental full-program characterization.
for unit in $units; do
  mode_env fpo "$gxc" \
    -O -d "$run_root/fpo/env/lib" \
    "$module_root/$unit"
done
mode_env fpo "$gxc" \
  -O -full-program-optimization \
  -d "$run_root/fpo/env/lib" \
  -exe -o "$run_root/fpo/bin/run" \
  "$main"
run_mode_env fpo "$run_root/fpo/bin/run"

git -C "$workbench_checkout" status \
  --porcelain=v1 --untracked-files=all \
  >"$run_root/attestation/workbench-dirty-paths-after.txt"
find "$run_root" -type f -print | sort \
  >"$run_root/attestation/generated-files.txt"
```

`-exe` and `-full-program-optimization` are final-combination flags, not library-unit modes; all other mode flags must be identical across every compiled unit in that mode. Never reuse a `HOME`, `TMPDIR`, `GERBIL_PATH`, object, executable, or output directory between modes. Every `gxc` invocation uses `-d`. Produced executables must run through `run_mode_env`; invoking them directly is invalid evidence because it could fall back to ambient `~/.gerbil` or loader variables. Source execution and compilation resolve the fixture root before the matching mode's `$GERBIL_PATH/lib`; produced executables resolve only the matching compiled library and installed Gerbil library, while runtime configuration uses its explicit source path. This avoids duplicate source/compiled module instances with independent live registries.

For M3 full-program characterization, if baseline full-program optimization loses runtime-evaluated definitions, repeat the full FPO build and execution in a fresh `fpo-retained` mode environment and add `-prelude '(declare (not optimize-dead-definitions))'` only to that final FPO combination command:

```sh
mode=fpo-retained
mkdir -p \
  "$run_root/$mode/env/lib" \
  "$run_root/$mode/bin" \
  "$run_root/$mode/home" \
  "$run_root/$mode/tmp"
for unit in $units; do
  mode_env "$mode" "$gxc" \
    -O -d "$run_root/$mode/env/lib" \
    "$module_root/$unit"
done
mode_env "$mode" "$gxc" \
  -O -full-program-optimization \
  -prelude '(declare (not optimize-dead-definitions))' \
  -d "$run_root/$mode/env/lib" \
  -exe -o "$run_root/$mode/bin/run" \
  "$main"
run_mode_env "$mode" "$run_root/$mode/bin/run"
```

Never reuse the failed FPO environment, and never report the retained retry as normal or `-O` production support (`research/fpo-runtime-config-options.md`; `research/gerbil-hermetic-runtime-matrix.md`).

These are future fixture commands, not commands run by this checklist revision. Before deleting `run_root`, copy the attestation files, exact commands, exit statuses, observable outputs, and the before/after checkout comparison into the milestone's durable evidence record. Confirm from that comparison that no generated compiler/runtime artifact appeared beneath either checkout. A result without the live dirty-path records or with ambient loader variables is invalid.

The GNU Emacs source baseline is annotated tag `emacs-30.2`: tag object `29f3f150af5c5b065c3a9f39969429e5bb3285da`, dereferenced commit `636f166cfc86aa90d63f592fd99f3fdd9ef95ebd`. Do not describe the tag-object identity as the source commit. The audit's focused probe is the reference oracle for independent cells, aliases, capture, and byte-compiled late lookup; its full convention probe covers dynamic restoration, context-local fallback, hooks, advice, and key-backed command dispatch. The audit records that those probes were not run during the read-only audit (`research/emacs-runtime-roadmap-audit.md`, “Validation commands”); run them only when reference-runtime verification is needed, never as a substitute for Gerbil results.

## Principal residual risks

- **High:** deployed runtime evaluation requires shipping and initializing the expander, having the launcher establish the intended compiled Tuna package environment, and accepting associated footprint and security consequences. User config discovery is deliberately not used to repair a missing runtime environment.
- **Low after M6:** typed action discovery and opaque-context dispatch are generation-coherent, but a sequence of separate discovery and invocation calls may legitimately straddle a concurrent replacement; no multi-call transaction is promised.
- **High:** runtime live identities and hygienic Gerbil identifiers form two namespaces that must remain visibly distinct; ordinary private Gerbil code must not drift onto live dispatch accidentally.
- **Medium:** true symmetric multiprocessing (SMP) contention remains unmeasured because the attested installed runtime reports SMP disabled even though individual cell operations and publication have been characterized.
- **Medium:** M5 proves generic context-local mechanics but no host currently defines context identity, ownership, lifetime, or inheritance; its API and terminology remain provisional.
- **Medium:** source/load provenance remains undecided; partial loads are the current contract, and unload remains unsupported absent a separate owner-approved plan and ADR.
- **Medium:** a captured forwarding wrapper is stronger than an extracted implementation snapshot and can confuse users if not named distinctly.
- **Medium:** the existing Gerbil checkout has dirty Gambit runtime files; later results need a recorded baseline or clean isolated checkout supplied by the owner.
- **Low after core pass:** deterministic hooks/events are ordinary library structures when live-name listeners dispatch through the proven seam, but host-specific keymaps are explicitly outside this runtime.
