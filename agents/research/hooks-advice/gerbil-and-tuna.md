# Gerbil advice feasibility and Tuna hook audit

**Recommendation:** advise plugin-owned commands, service interfaces and hook objects; add explicitly declared advisable points only where a package needs them. Use documented macros, typed records, closures and module-owned setters; compose on registration changes, not every call. **Arbitrary existing exported bindings cannot generally be advised idiomatically under the owner's no-hacks requirement.** `separate` does not prevent Gerbil's typed-call rewrites, and foreign rebinding cannot provide transparent redefinition persistence.

## Evidence key and limits

- **Observed** means inspected implementation or the isolated experiments below. **Rationale** means an existing decision/document's explanation. **Inference** means a recommendation or deduction, not an implemented feature.
- `T:path:line` refers to Tuna commit **`57a2b4536cd371ffcf6701563019cd00364bdec6`**. `G:path:line` refers to Gerbil commit **`1cfb032c7a1612637da6205f5f8a15683eba3ba0`**, the installed compiler: **v0.19-dev-63**, Gambit **v4.9.8-19-gea114fc3**. The Gerbil checkout is at `1c6c15385979f0092574fbc2b828f3fb656319b3`; the compiler, contract, driver, runtime-interface and std-interface files cited below have no differences from installed commit `1cfb032c`.
- `B:path:line` refers to Gambit submodule commit **`ea114fc3d2f120abbe20393c1f9aeafdd3f8c89f`**; paths start inside `gerbil/src/gambit/`. `E:path:line` refers to Emacs **`541f693ca2e8de166cfe52c39bbfc497142215e9`**.
- `X` is the untracked experiment directory **`/home/jay/Code/workbench-gerbil/scratch/hooks-advice/`**. Sources, generated Scheme and results remain there. No Tuna build, runtime or test suite was run; no product source changed. Every compiler/interpreter invocation ran there under `systemd-run --user --scope -p MemoryMax=4G -p MemorySwapMax=0 timeout 600`.

Reproduce the compiled probes from `X` (the first invocation builds only throwaway modules):

```sh
systemd-run --user --scope -p MemoryMax=4G -p MemorySwapMax=0 timeout 600 bash -c '
  set -e; export GERBIL_LOADPATH="$PWD"
  /opt/gerbil/bin/gxc -O -s -d . separate.ss block.ss typed-live.ss mutable.ss
  /opt/gerbil/bin/gxc -O -s -d . caller.ss bench.ss typed-live-caller.ss mutable-caller.ss hook-shape.ss
  for script in experiment typed-live-run mutable-run hook-shape-run session-shape-run bench-run; do
    /opt/gerbil/bin/gxi "$script.ss"
  done'
```

## A. What Gerbil actually permits

### Globals, optimization, and replacement

**Observed:** Gerbil lowers a module definition to a qualified Gambit global, e.g. `separate#f`; exported imports resolve to that binding, not a copied procedure. The generated code has an initial `(declare (block))`, followed by the module's `(declare (separate))`. The latter removes Gambit's assumption that globals not assigned in the compilation unit never change. Sources: `G:src/gerbil/compiler/driver.ss:787-797`, `G:src/gerbil/expander/compile.ss:159-175`, `B:doc/gambit.txi:4904-4910`; generated `X/separate~0.scm:1-10`. Tuna's prelude injects this declaration without rewriting `def` (`T:tuna/prelude.ss:14-20`).

The compiled experiment uses **library imports** (`:separate`, `GERBIL_LOADPATH=X`) after `gxc -O -s -d .`; string-path imports initially loaded source and concealed the block/separate distinction. `X/experiment.ss:1-15` tests imported `set!`, `eval` of imported `set!`, module-context evaluation and raw global mutation. **Module-context evaluation, module-internal lookup and `##global-var-set!`/`##make-global-var` are hack, not recommended.** Cross-module `set!` is feasibility evidence only, not the proposed architecture; all recommended mutations happen through the defining module's own installer.

| Observed after replacing `x + 1` with `x + 10` | Separate, ordinary `def` | Block, ordinary `def` | Separate, typed `def` |
|---|---:|---:|---:|
| Binding called from the evaluator, argument 1 | 11 | 11 | **2** |
| Previously compiled same-module caller | 11 | **2** | **2** |
| Previously compiled other-module caller | 11 | 11 | **2** |
| Previously saved ordinary procedure value | **2** | — | — |

The typed binding's underlying global **was changed**: a raw global read and application returns 11 (`X/typed-live-run.ss:1-6`, `X/results.txt`). However, Gerbil's typed-definition expansion creates `__typed`; optimized callers select that unchecked entry when argument types are known. The evaluator also expands typed calls through that entry. Even adding a local setter did not prevent it. A `:t` argument/return signature showed the same bypass. Sources: `G:src/gerbil/compiler/optimize-call.ss:189-203`; generated `X/separate~0.scm:11-39`, `X/caller~0.scm:6-10,28-35`; `X/separate.ssxi.ss:50-64`.

**Inference:** `separate` governs Gambit optimization, not all Gerbil rewrites. Neither stronger namespace lookup nor `##global-var-set!` repairs callers already routed elsewhere. Saved closures also remain saved closures. Mutating generated `__` names is also **hack, not recommended**: they are compiler implementation details, and wrappers could violate the contracts optimized callers assume. Full-program optimization is separately unsupported by ADR 1 (`T:agents/adr/0001-language-and-extension-surface.md:28`); it was not tested here.

**Observed source-only precedent, not a recommendation:** Gerbil provides `defmutable`, an identifier macro expanding references to one mutable global and `set!` to a setter (`G:src/gerbil/core/contract.ss:3792-3818`). This source preserved a typed implementation while all three call sites changed from 2 to 11 under `-O`:

```scheme
(defmutable f
  (lambda ((x : :fixnum)) => :fixnum (fx+ x 1))
  : :procedure)
```

See `X/mutable.ss`, `mutable-caller.ss`, `mutable-run.ss`, and generated `mutable~0.scm:6-45`. No public documentation was located for this macro, so the recommendations below do **not** depend on it. It is not proof for ordinary typed `def` or advice persistence: its setter still overwrites the effective value. The documented-record alternative below also avoids the old atom-backed framework rejected by ADR 1 (`T:agents/adr/0001-language-and-extension-surface.md:7,32`).

### What live evaluation and late hook lookup mean today

**Observed:** `init.ss` keeps imports at module scope but wraps user definitions inside the activation body of `init`; those definitions are local. The session evaluator instead retains a child `top-context`, imports `:tuna/config`, updates its parent to the loaded configuration module, and runs `eval` under `session-owner`. `evaluate-forms` stops at the first exception without undoing earlier effects. The persistence plugin `plugins/session` saves data; it does not implement this evaluator (`T:tuna/config.ss:103-133`; `T:tuna/boot.ss:1256-1311`; `T:tuna/configuration.ss:61-70`; `T:plugins/session/plugin.ss:13,166`).

An equivalent isolated top-context experiment shows imported `(set! f ...)` changes the package global; `(def (f ...) ...)` creates a session-local definition instead: evaluator calls return 21 while the module and its internal caller still return 11 (`X/session-shape-run.ss`, `session-results.txt`). **Inference:** “evaluate this defun” is not automatically “replace its imported module binding.” An idiomatic evaluator can call the package's public declared-point installer; it must not switch into another module's internals. The latter is **hack, not recommended**, despite working experimentally.

The existing late-hook test explicitly declares `separate`, registers `late-hook-callback` twice, assigns it locally, checks the new callback, and restores it (`T:tuna/tests/unit/plugins-test.ss:12,30,293-312`). The registration macro emits `(lambda args (apply function args))`; another wrapper binds the registering context (`T:tuna/kernel/plugins.ss:84-86,176-205`). **Observed:** compiled imitation of that rest/apply wrapper sees a new typed callback, whereas `(lambda (x) (function x))` and a direct typed call retain the old implementation (`X/hook-shape.ss`, `hook-shape-run.ss`, `results.txt`: `((new 1) 1 1)`). **Do not replace the late-lookup wrapper with a direct fixed-arity call without this regression test.** The existing test proves that registration shape, not universal typed-function redefinition.

### Measured call cost

`X/bench.ss:4-8` compiles an external caller of the ordinary separate-module function, plus wrapper factories; `bench-run.ss:3-17` installs each compiled wrapper, warms 100,000 calls, and runs five samples of 20,000,000 calls with checked checksums. CPU time includes the loop, arithmetic and any allocation/garbage collection. AMD Ryzen 9 7940HS, x86-64; not CPU-pinned. A fresh rebuild/reproduction passed all probes; final samples: `X/reproduction-results.txt` (earlier samples remain in `X/results.txt`).

| Call path | Median ns/call | Five-sample range |
|---|---:|---:|
| Unwrapped | 5.08 | 5.08–5.12 |
| One fixed-arity forwarding closure | 5.64 | 5.62–5.74 |
| One rest-argument/`apply` forwarding closure | 29.53 | 29.03–30.16 |

**Inference:** bare fixed-arity forwarding adds roughly 0.6 ns here; generic forwarding adds roughly 24.5 ns and allocation pressure. These are lower-bound forwarding measurements, **not** measurements of real `before`/`around` advice, context binding, hook dispatch or interface decorators. Generate arity-specific composition where safe, retain ordinary no-advice calls, and benchmark the actual typed binding strategy before selecting it.

### Costs of the recommended documented mechanisms

**Observed:** `X/idiomatic-shapes.ss` uses only ordinary definitions/module-owned mutation, documented `defrule`, typed `defstruct` fields and `:std/interface` implementations. The declared-point macro stores its effective closure in a private record, not a directly rebound typed function. Its typed public facade reads that field; a separately compiled caller observes a replacement through the public installer (`X/idiomatic-shapes-caller.ss`, `idiomatic-shapes-check.ss`). Additional assertions confirm command-entry updates, service-decorator updates and callback execution through both hook runners (`X/idiomatic-shapes-check-results.txt`). A first attempt storing a typed function directly in a mutable global reproduced the unchecked-entry bypass and was rejected. Documentation: `G:doc/reference/std/sugar.md:12-24` (`defrule`); `G:doc/reference/gerbil/prelude/macros.md:431-495` (records/mutation); `G:doc/reference/std/interface.md:14-36`.

Five samples of 10,000,000 calls, checked loop checksums, compiled target bodies, CPU 0 affinity; medians below include loop arithmetic. Logs: `X/idiomatic-shapes-pinned-results.txt`. “Advised” installs one **forwarding** closure: a lower bound excluding useful advice work, receipts, composition/installation time and Tuna's surrounding task/context/error-handling machinery. These are measured standalone implementations of the recommended shapes, **not full Tuna integration benchmarks**.

| Recommended shape | Unadvised ns/call | With one forwarding advice ns/call |
|---|---:|---:|
| Explicit macro-declared point, typed facade + private record | 6.06 | 7.16 |
| Command registry lookup + zero-argument entry invocation | 38.61 | 39.39 |
| Typed service dispatch; advised case adds ordinary typed decorator + forwarding closure | 2.91 | 7.59 |
| Generic hook runner, empty callback list, one argument | 17.26 | 40.62 |
| Same hook runner, one callback | 31.18 | 55.72 |

Direct typed arithmetic in the same harness costs **2.83 ns**; declaring a point therefore adds about **3.23 ns even when unadvised**. Only declare points that need interposition. A service decorator without the extra forwarding-advice closure costs **6.29 ns**; when no advice exists, retain the original provider shell. Command differences under 1 ns are near run noise; do not claim a reliable percentage. Hook advice's generic rest/apply hop adds roughly 23–25 ns here. A typed, arity-specific hook runner could avoid that hop but is not measured or recommended as a universal replacement for existing dynamic callbacks.

Reproduce these additional probes from `X`:

```sh
systemd-run --user --scope -p MemoryMax=4G -p MemorySwapMax=0 timeout 600 bash -c '
  set -e; export GERBIL_LOADPATH="$PWD"
  /opt/gerbil/bin/gxc -O -s -d . idiomatic-shapes.ss
  /opt/gerbil/bin/gxc -O -s -d . idiomatic-shapes-caller.ss
  /opt/gerbil/bin/gxi idiomatic-shapes-check.ss
  taskset -c 0 /opt/gerbil/bin/gxi idiomatic-shapes-run.ss'
```

### Four advice targets and definition updates

The following is **proposed design**, not existing API:

| Target | Idiomatic attachment point | Important constraint |
|---|---|---|
| Command | Compose the effective command body's procedure when definition/advice changes; retain command metadata and owner. | Keep invocation inside the existing activation/pre/post-hook and task-owner envelopes. Do not register a competing command under the advisor's owner: that changes ownership, cancellation and help. `T:plugins/commands/plugin.ss:18-43`; `T:plugins/commands/contract.ss:36-56`. |
| Service method | Generate an ordinary typed interface decorator forwarding unadvised methods to the original provider. Cache the effective decorated view when advice changes. | Interface instances contain cached method procedures; rebinding a dispatcher or class method does not repair existing shells. Never mutate shared Gerbil prototype caches. `G:src/gerbil/runtime/interface.ss:96-134,204-211`; `G:doc/reference/std/interface.md:14-36`. |
| Hook | A composed runner associated with the hook object, around its ordinary callback iteration. Callback advice, if wanted, is a distinct target identified by owner/name. | A hook is an object, not a function binding; adding an early/late callback cannot express `around` or `override`. A hook runner must preserve callback isolation, quit handling and snapshot semantics. `T:tuna/kernel/hooks.ss:34-47`; `T:tuna/kernel/plugins.ss:211-229`. |
| Exported package procedure | **No general arbitrary-binding solution within the approved idioms.** A package may explicitly declare an advisable point: a macro generates a stable typed facade, private typed record and module-owned installer. | Only declared points participate. The facade reads the record's effective procedure; its public/unchecked compiled entries remain unchanged. The installer updates the point, never another module's variable. Ordinary non-declared functions stay ordinary and unadvisable. |

Service decoration cannot currently be installed as a second provider: `context-provide!` rejects one, and the kernel caches the provider itself (`T:tuna/kernel/plugins.ss:374-417`). **Inference:** add a deliberately small generic decoration seam with separate base/effective views; generate typed decorator code outside the kernel. Changing advice must not masquerade as provider replacement or restart dependents. Previously captured interface handles and provider-internal self-calls would remain outside service-boundary advice unless the contract explicitly changes. The brief must state that boundary and justify any kernel addition under ADR 12, not quietly patch registry internals.

For all targets, keep **current base definition + ordered named advice records + composed effective procedure**. Rebuild on add/remove/redefine; a receipt removes its record by identity, not by restoring an old pointer. Carry the advisor's context for registrations its callback creates, and preserve the target owner's execution lifetime. Generate the ten ADR 1 combinators from this one composition model. Specify Scheme-specific multiple values and truthiness (`#f` only), keyword/rest arguments, normal-return `after` versus cleanup-on-exit, and exception/quit propagation before implementing filters and conditional combinators.

**Observed prior art:** Emacs intercepts definition installation through `defalias-fset-function` and substitutes the new base beneath existing advice (`E:lisp/emacs-lisp/nadvice.el:477-503,535-537`; [immutable source](https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/lisp/emacs-lisp/nadvice.el#L477-L503)). **Inference:** copy the explicit definition-update protocol, not symbol-cell manipulation. A declared point's installer replaces its base while preserving its advice records; removing the last advice reveals the **latest base**, not the pre-advice original. Raw `set!` and module re-evaluation bypass library bookkeeping; preserving advice across arbitrary foreign rebinding is outside the idiomatic design. Reload must re-register the declared identity/update its existing point through that protocol, not manufacture a replacement point and strand its advice. Restricting targets is a deliberate ADR 1 change, preferable to compiler changes or internal mutation tricks.

Gambit `trace` is precedent, not an advice engine: it traces interpreted procedures; for a compiled global procedure it warns, creates an interpreted wrapper, rebinds the global, then installs entry hooks (`B:doc/gambit.txi:3014-3042`; `B:lib/_repl.scm:2312-2352,2554-2586`). This does not solve block/direct-call bypass, ownership or redefinition persistence. Repurposing its debugger internals is **hack, not recommended**; none of the proposed mechanisms uses them.

## B. Complete hook/use inventory

All inventory references below are **T**. Names omit the `-hook` suffix. “Registrations” lists production `context-add-hook!` sites; all callbacks use their hook's argument shape. Every current hook is a notification: `run-hook` returns void and **no caller uses callback results or until-success semantics** (`tuna/kernel/plugins.ss:211-229`).

| Hook; definition | Arguments; invocation sites | Production registrations |
|---|---|---|
| plugin-activated; `tuna/kernel/plugins.ss:254-256` | `(plugin)`; recorded at `:513` | `tuna/config-blocks.ss:49`; `plugins/session/plugin.ss:285` |
| plugin-deactivated; `tuna/kernel/plugins.ss:258-260` | `(plugin)` after receipt; recorded at `:465` | `tuna/config-blocks.ss:54` |
| service-changed; `tuna/kernel/plugins.ss:265-267` | `(service old-or-#f new-or-#f)`; recorded at `:416-417` | `plugins/completion/plugin.ss:238`; `plugins/completion-vertical/plugin.ss:152` (depth −10) |
| task-started; `tuna/kernel/loop.ss:80-82` | `(id name)`; lifecycle runner at `:442` | None |
| task-finished; `tuna/kernel/loop.ss:91-93` | `(id name returned\|raised\|quit)`; lifecycle runner at `:500` | None |
| configuration-started; `tuna/configuration.ss:74-75` | `()`; `tuna/boot.ss:1250` | `plugins/session/plugin.ss:276` (restore) |
| configuration-stopping; `tuna/configuration.ss:76-77` | `()`; `tuna/main.ss:163` | `plugins/session/plugin.ss:279` (save) |
| configuration-report-ready; `tuna/configuration.ss:78-79` | `(configuration-report)`; `tuna/main.ss:113-119` | `plugins/reload-config/plugin.ss:52` |
| pre-command; `plugins/commands/contract.ss:21` | `()`, identity through `this-command`; `plugins/commands/plugin.ss:29` | None |
| post-command; `plugins/commands/contract.ss:22` | `()`; `plugins/commands/plugin.ss:30` | `plugins/completion/plugin.ss:245` (refresh current completion) |
| after-change; `plugins/buffers/contract.ss:278-279` | `(text change)`; `plugins/buffers/plugin.ss:85` | None |
| kill-buffer; `plugins/buffers/contract.ss:629-630` | `(buffer)` before removal; `plugins/buffers/plugin.ss:367` | `plugins/layout/plugin.ss:909`; `plugins/completion-vertical/plugin.ss:146` |
| buffer-list-update; `plugins/buffers/contract.ss:634-635` | `()`; contract `:563,620,647` after rename/add/kill | None |

`change` carries revision, start, removed and inserted strings (`plugins/buffers/contract.ss:98-102`); report fields are text, problem, entries and log (`tuna/configuration.ss:81-83`). Production callbacks restore/save session slots, synchronize config blocks, redraw completion or release references to killed buffers. None requests a veto or result aggregation.

The generic plumbing also contains `apply run-hook` in `tuna/kernel/plugins.ss:279`; lifecycle recording invokes `run-lifecycle-hook` at `:285,339`. Imports, exports and comments are not invocation sites. There are **13 production hook objects**. No job, redraw, input-arrived or screen-delivered hook currently exists under `tuna/` or `plugins/`; the profiler brief's kernel/job row is a proposal, not built evidence (`docs/briefs/2026-10-profiler.md:60-67`).

### Test-only hooks and all remaining use sites

These compact lists complete the requested `tuna/` and `plugins/` inventory, including test support:

- `tuna/tests/unit/plugins-test.ss`: defines `test-hook` at **48**, and a local `other-hook` at **319**. Registrations at **52–54,66,68,70,84,89,185,238,300–301,323,326**; runs at **188,242,305,308,334,427,493**. Shapes: test hook `(item)`; other hook `()`; lifecycle shapes as above. Exercises ordering, failures, owner context, duplicate replacement, receipt size, redefinition and cross-kernel isolation.
- `tuna/tests/unit/loop-test.ss`: defines `quitting-hook` at **89**. Registrations at **75,77,82–83,87,95–96,142,144,149,167**; runs at **102,499,590**. Quitting hook takes `()`; task/lifecycle shapes as above. Exercises quit, failure, forbidden lifecycle mutation and task reporting; the loop-holder callback deliberately blocks as test synchronization.
- `plugins/commands/tests/integration/commands-test.ss`: pre/post registrations **59,61**, both `()`; checks nested programmatic commands without an input provider at **50–69**. `plugins/commands/tests/support/toy-commands.ss`: corresponding runs **22,25**.
- `plugins/buffers/tests/support/toy-buffers.ss`: after-change run **104** `(text change)`, kill-buffer run **265** `(buffer)`.
- `plugins/completion/tests/support/toy-completion-ui.ss`: kill-buffer registration **37** `(buffer)`; service-changed registration **50** `(service outgoing incoming)`, depth −10.
- `plugins/layout/tests/support/two-views.ss`: kill-buffer registration **115** `(buffer)`.

### Assessment

- **Command hooks already exist and work independently of keys.** The commands plugin runs them for named invocation, including nested `call-command`; keys calls that contract (`T:plugins/keys/plugin.ss:201`). Post runs during unwinding once the command body was entered; a quit from pre can prevent entry and post. ADR 8's amendment already assigns them to commands, contradicting older STATUS/profiler wording about the input plugin (`T:agents/adr/0008-input-keymaps-and-command-composition.md:47-49`). Do not add a second pair.
- **Snapshot ordering is sound for the current execution model.** Writers hold the hook mutex and replace the list; callbacks execute outside that lock. Replacement retains serial order, and receipt removal uses identity (`T:tuna/kernel/hooks.ss:58-88`; `T:tuna/kernel/plugins.ss:176-191`). Reads/filtering are unlocked. Installed runtime reports non-SMP. **Inference:** immutable snapshots avoid iterator corruption, but the mutex does not make receipts, callbacks or editor state thread-safe; register/run on the baton (`T:tuna/kernel/state.ss:1-2`). Concurrent registration can interleave old-record lookup, list installation and receipt mutation. Do not advertise arbitrary-thread registration safety. Removal during a run deliberately takes effect next run, so a removed callback may still run from the current snapshot.
- **Per-kernel isolation has a real but bounded cost.** Each dispatch filters all kernels' callbacks and allocates a list for its matching callbacks; registration scans too (`T:tuna/kernel/hooks.ss:63-77,85-92`; `T:tuna/kernel/plugins.ss:181-185`). Cost is proportional to **all registered callbacks**, not just this kernel's. A singleton hook retains dropped kernels until callbacks are removed; the isolation test intentionally leaves one behind (`T:tuna/tests/unit/plugins-test.ss:484-497`). **Inference:** keep this straightforward model for the normal one-kernel process; profile before adding per-kernel indexing. Always deactivate test kernels. “No listeners” is cheap, not literally zero overhead, especially with argument-list construction.
- **The late-lookup lambda is functional, not incidental boilerplate.** It preserves value lookup and avoids the typed direct-call bypass demonstrated above. Closure expressions intentionally retain their captured values; identifier syntax alone does not make a lexical binding globally redefinable. Keep context binding: callbacks may register more effects under their owner (`T:tuna/tests/unit/plugins-test.ss:181-191`).
- **Failure isolation is decided policy, with a cleanup gap.** A failure removes only the callback and reports its hook/name/owner; quit has separate task/plugin-operation semantics (`T:tuna/kernel/plugins.ss:211-229,299-343`; rationale `T:agents/adr/0002-plugins-contexts-and-services.md:23`). Removal does not remove the callback's inverse from its owner's receipt. **Inference from the two paths:** repeated fail/re-register cycles retain obsolete inverses and their callback closures until deactivation; clean that receipt entry when disabling a callback. Preserve isolation, but expose enough failure information to re-register/debug it. Do not automatically apply notification-hook suppression to advice: a failed advice/body should not silently turn into a successful return.
- **Local scope is not implemented and current consumers do not require it.** Existing observers genuinely span buffers, or can filter the explicit text/buffer argument. **Inference:** future modes and text-node-specific listeners will need scoped registration; avoid a kernel dependency on buffers or an implicit “current buffer.” Prefer a contract-owned text/node/buffer scope built on the generic mechanism when its first concrete user arrives. A text can be observed independently of the selected view; attaching every text listener to a buffer would conflate those identities (`T:plugins/buffers/contract.ss:8-25,276-279`). No current use justifies until-success dispatch; add a separately named runner only with a real result-producing use.

## Implications for Tuna

1. **Amend ADR 1 explicitly:** arbitrary exported-function advice is not available idiomatically under these constraints. Recommend commands/services/hooks first, plus opt-in macro-declared points when genuinely needed. Keep typed public facades and module-owned installers; do not replace all `def`s, weaken typing, modify the compiler or use foreign rebinding, module-context evaluation or Gambit internals.
2. **Keep advice records separate from definitions.** Compose on mutation, retain the latest base, make owner/name replacement idempotent, and remove records by identity. Specify how module reload and session evaluation enter that update path. A save-pointer/restore-pointer implementation is incorrect after either another advisor or a redefinition.
3. **Use each concept's real seam:** commands owns command advice and already owns pre/post hooks; service advice decorates typed provider views without becoming a second provider; generic hook advice wraps the runner, not a fake callback. General composition belongs in a shared library; only genuinely necessary generic hook/service installation primitives belong in the kernel, with an ADR 12 amendment.
4. **Preserve the cheap disabled path.** No per-function atom registry, per-call sorting, namespace lookup or `eval`. The measurements above cover each recommended shape; actual Tuna integration still needs focused measurements. Use fixed-arity composition at declared points, where a typed record guarantees dynamic lookup; keep rest/apply for existing plain named-hook bindings, where direct-call optimization would bypass updates.
5. **Keep the current hook mechanism.** Fix failed-callback receipt retention, document baton/snapshot behavior, and retain owner context and quit distinctions. Do not add per-kernel indexing, buffer-local state or until-success semantics without a measured or concrete need.
6. **Make acceptance behavioral:** two owners advise one target; removing either leaves the other; redefining the base preserves both; removing the last reveals the newest base; disabling an advisor cleans its effects; command cancellation/provenance and multiple values survive; typed compiled callers really execute the advice. Add cross-module named-hook tests before optimizing the existing wrapper.
