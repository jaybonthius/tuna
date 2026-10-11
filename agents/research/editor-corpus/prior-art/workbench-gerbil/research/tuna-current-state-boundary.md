# Tuna current state boundary

## Concise answer

Tuna currently has a host-neutral **serialized action executor**, not an application-state runtime. It provides an instance-owned bounded queue, one worker, dequeue-time live action resolution, per-command completion, ordinary failure containment, and drain-on-stop. Any application-agnostic state approach must preserve those semantics while keeping state **opaque, instance-scoped, and confined to one command lane by contract**.

The live value system is unsuitable as authoritative application state: it is process-wide, directly mutable from any thread, non-transactional across cells, and its context-local layer has deliberately undefined host identity and lifetime. The roadmap’s M9 therefore requires a real host state contract before adding coherent revisioned snapshots and bounded, coalesced invalidation—but does not yet define how actions receive state, produce transitions, register subscribers safely, or order publication relative to command completion.

**Attested source state:** nested Tuna checkout is clean at `806ece2dfd58c1ddd121e19f5b359f27a40a0e73`. The roadmap and prior boundary research are present but untracked in the enclosing repository.

## Existing seams and constraints

### 1. Ownership and serialization

- `CommandRuntime` owns only an inbox, lifecycle mutex/state, and worker thread; it has no application-state field: `tuna/lib/runtime.ss:21-31`.
- Construction requires a positive bounded capacity and creates a distinct channel and mutex per instance: `tuna/lib/runtime.ss:39-46`.
- Exactly one named worker consumes requests sequentially: `tuna/lib/runtime.ss:105-117,119-139`.
- M8 deliberately permits multiple runtime instances and says application state remains opaque and owner-confined **by contract**, with no process-global singleton: `plans/emacsen-runtime/checklist.md:260-270`.
- Live function, action, and value registries are instead process-wide stable-cell registries with synchronized publication and per-thread caches: `tuna/lib/bindings.ss:54-88,90-131`. Multiple command runtimes therefore share action definitions and global live values even though their queues are independent.

**Constraint:** authoritative state must not become another process-global live value merely for convenience. If multiple runtime instances can reach the same mutable state, the single-lane guarantee is lost unless ownership is separately enforced.

### 2. Admission and execution

- Requests contain only action name, mode, payload, and completion: `tuna/lib/runtime.ss:25-31`.
- Public submission validates an interned symbol and list-shaped explicit arguments before admission: `tuna/lib/runtime.ss:141-152`.
- Admission is immediate and nonblocking: `accepted` with a completion, `full` with `#f`, or `not-running` with `#f`: `tuna/lib/runtime.ss:154-172`.
- Submission and stop use the same runtime mutex, so stopping linearizes against admission: `tuna/lib/runtime.ss:154-162,178-190`.
- Payloads remain caller-created objects held by reference. Acceptance transfers their ownership until completion; callers must not mutate them: `tuna/lib/runtime.ss:141-142`; `tuna/README.md:115-117`.
- One channel supplies a total execution order, but ordering between concurrent producers is whichever submission acquires admission first. Tests assert no handler overlap and only per-producer order, not cross-producer fairness: `tuna/test/command-runtime-test.ss:195-216`.

**Constraint:** preserve bounded immediate admission, late rejection without a completion, immutable-by-contract payload ownership, and dequeue-order execution. Copying arbitrary opaque contexts is not generally possible.

### 3. Action invocation

- An action generation atomically groups its implementation, public host descriptor, and context-to-arguments acquirer in one `ActionDefinition`: `tuna/lib/bindings.ss:31-40,202-217`.
- Explicit submission eventually invokes `invoke-action`; context submission invokes `invoke-action-with-context`: `tuna/lib/runtime.ss:65-85`.
- Both resolve the current action when the worker executes the dequeued request, so queued work observes later action replacement: `tuna/lib/runtime.ss:71-79`; verified at `tuna/test/command-runtime-test.ss:136-160`.
- Context invocation snapshots one action generation, runs its acquirer on the opaque context, requires a list, then invokes that same generation: `tuna/lib/bindings.ss:236-258`.
- Direct programmatic invocation bypasses the command runtime and remains public: `tuna/lib/bindings.ss:247-258`; exports at `tuna/lib/prelude.ss:19-22`.

**Constraint:** state integration cannot move action lookup to admission time or split implementation/acquirer generations. Existing actions receive explicit arguments only; the opaque context acquirer currently has arity `context -> arguments`. How current state reaches an action is unresolved and cannot be changed silently without altering the M6 contract.

### 4. Dynamic and context-local values

- Dynamic bindings use thread-local storage plus `dynamic-wind`, restoring after every supported exit: `tuna/lib/bindings.ss:332-337,484-494`.
- They are not inherited by spawned threads; global live cells remain shared: `tuna/README.md:234-238`.
- Context selection uses a Gerbil parameter and is inherited by spawned threads: `tuna/lib/bindings.ss:85-88,305-311`; `tuna/README.md:257-264`.
- Context-local cells are independently mutable, mutex-published overlays that fall back to global value cells: `tuna/lib/bindings.ss:301-326,343-354,457-482`.
- Automatic localization occurs on first assignment in a context, after checking for an active dynamic binding: `tuna/lib/bindings.ss:400-420`.
- The roadmap explicitly leaves context identity, ownership, lifetime, sharing, inheritance, and cleanup to a future host: `plans/emacsen-runtime/checklist.md:189-205,336-344`.

**Constraint:** M5 contexts must not be reinterpreted as application state, request state, editor buffers, or browser sessions. A worker started inside a value context inherits it, creating a hidden ambient dependency unless state handling explicitly avoids M5.

### 5. Failure behavior

- Action, acquirer, undefined-action, and acquired-argument errors are returned through the accepted command’s completion; the worker continues: `tuna/lib/runtime.ss:65-85`.
- Tests cover original exception propagation followed by successful recovery: `tuna/test/command-runtime-test.ss:162-170`.
- A fatal loop-level exception changes lifecycle state to `failed`, closes the inbox, fails queued requests, then escapes the worker: `tuna/lib/runtime.ss:87-117`.
- There is no transactional rollback. An action may mutate live values, a host closure, external resources, or future state before raising; those effects remain: `plans/emacsen-runtime/checklist.md:84-99,225-227`; `tuna/README.md:240-246`.
- Completion waiting has no timeout: `tuna/lib/runtime.ss:174-176`; underlying behavior at `gerbil/src/std/sync/completion.ss:33-44`.

**Constraint:** “command failure leaves state unchanged” is not current behavior. It would require a new transition or staging contract. Existing ordinary failure containment only protects worker liveness and completion delivery.

### 6. Shutdown and drain

- Stop from `created` closes immediately as `stopped`; stop from `running` becomes `stopping` and closes the inbox; repeated stop is harmless: `tuna/lib/runtime.ss:178-190`.
- Gerbil channels drain queued values before returning end-of-file: `gerbil/src/std/sync/channel.ss:77-115,117-127`. The worker therefore finishes accepted requests before setting `stopped`: `tuna/lib/runtime.ss:105-113`.
- Join waits for the retained worker; the standalone wait loop uses finite joins only to avoid Gambit’s idle deadlock detector: `tuna/lib/runtime.ss:192-210`.
- Tests cover queued draining, concurrent submit/stop linearization, and late rejection: `tuna/test/command-runtime-test.ss:172-193,218-246`.
- `main` loads configuration, starts the runtime, waits, then stops/joins it before shutting down logging: `tuna/main.ss:11-31`; logger drain is `tuna/lib/log.ss:23-30`.
- Cancellation, deadlines, priority, operating-system signals, and long-action offload remain excluded: `tuna/README.md:119-123`; `plans/emacsen-runtime/checklist.md:268-272`.

**Constraint:** drain is currently unbounded. A blocking or non-yielding action can prevent shutdown and keep payload ownership indefinitely.

### 7. Configuration and package boundaries

- Startup chooses one optional XDG file, one explicit existing file, or no config; arguments do not layer: `tuna/lib/startup.ss:6-31`.
- Config begins as ordinary Gerbil, explicitly imports Tuna/packages, and evaluates forms sequentially. Earlier mutations survive later failure: `tuna/lib/config.ss:29-41`.
- Runtime package resolution remains launcher/deployment responsibility; config loading does not mutate load paths or derive language from neighboring package metadata: `tuna/README.md:64-77,180-191`.
- Config is loaded before the command worker starts: `tuna/main.ss:14-23`.
- Independent packages select the Tuna prelude only where they publish live extension points; private implementation remains ordinary lexical Gerbil: `packages/dummy/gerbil.pkg:1`; `packages/dummy/plugin.ss:15-29`; roadmap at `plans/emacsen-runtime/checklist.md:245-258`.
- Core runtime imports no HTTP, editor, rendering, or Datastar module: `tuna/lib/runtime.ss:3-6`.

**Integration seam:** a host-specific package can encapsulate its state and adapters in ordinary lexical Gerbil while exposing host-neutral actions. Tuna need not know whether producers are HTTP handlers, terminal input, timers, or another host.

## Exact M9 boundary

Current M9 says:

- A **concrete host state model** must publish coherent revisioned snapshots through bounded, coalesced invalidation channels: `plans/emacsen-runtime/checklist.md:276-279`.
- A future Command Query Responsibility Segregation read side learns only that newer state exists; it need not receive every intermediate render: `plans/emacsen-runtime/checklist.md:280-282`.
- The minimal mechanism is one stable snapshot cell and one capacity-one channel per subscriber; it is latest-state invalidation, not a durable or lossless domain-event log: `plans/emacsen-runtime/checklist.md:282-284`.
- M9 must not begin before a real host state contract and must not introduce HTTP, Server-Sent Events, Datastar, browser sessions, rendering, persistence, event sourcing, or brokers: `plans/emacsen-runtime/checklist.md:286`.
- Its dependency is M8 plus approved host state: `plans/emacsen-runtime/checklist.md:387-400`.
- M9 and later also require explicit owner direction and their evidence gates: `plans/emacsen-runtime/checklist.md:62-68`.

The earlier research proposed combining state ownership and publication with the command runtime: `research/tuna-long-lived-command-runtime-boundary.md:34-74`. The implemented roadmap deliberately split that proposal: M8 now contains execution only, while state/publication is deferred to M9. The historical proposal is therefore design evidence, not current behavior.

## Materially different introduction points

These are integration boundaries, not a final design:

1. **Extend `CommandRuntime` internally.**  
   The sole worker boundary is `complete-command!`/`run-command-runtime!`: `tuna/lib/runtime.ss:65-117`. A coherent install or publication would need to occur there before the existing completion post at line 83. This provides strongest ownership but requires resolving how existing actions consume or return state.

2. **Compose a separate generic state component with the runtime.**  
   A separate snapshot/revision owner could keep the executor API stable, but atomic action/commit ordering and direct invocation escape would need an explicit contract. Post-processing completions alone cannot undo partial action mutation.

3. **Keep state entirely in an independently compiled host package.**  
   Private lexical package state or a capability-carrying closure can be reached only through chosen actions, leaving Tuna editor/server agnostic. This preserves package boundaries but ownership remains contractual because direct action/value APIs and multiple runtimes are public.

4. **Do not use live values or M5 contexts as the state store.**  
   They are useful configuration/dynamic facilities but provide neither instance ownership, coherent multi-cell snapshots, revisions, nor publication.

## Findings, gaps, and hidden assumptions

- **High — ownership is not enforceable:** public actions and values remain callable/mutable from arbitrary threads, bypassing the command lane (`tuna/lib/bindings.ss:247-258,385-446`). A state approach needs a capability or strict host contract; queue serialization alone is insufficient.
- **High — long or partially mutating failures:** actions may mutate then fail, and a long action blocks every command and unbounded shutdown drain (`tuna/lib/runtime.ss:65-85,178-210`). No rollback or cooperative cancellation exists.
- **Important — no state/action bridge:** M8 stores no application state, while existing action/acquirer signatures do not receive authoritative state (`tuna/lib/runtime.ss:21-31`; `tuna/lib/bindings.ss:247-258`). M9 cannot be connected without defining this boundary.
- **Important — ambient context inheritance:** the worker inherits the value context active during `command-runtime-start!`, although submitted host contexts are separate opaque payloads (`tuna/lib/bindings.ss:85-88`; `tuna/README.md:260-264`).
- **Medium — M9 lifecycle underspecified:** subscriber registration races, initial snapshot acquisition, unsubscribe/cleanup, channel closure, revision type/change detection, publication failure, and publication-versus-completion ordering are not stated at `plans/emacsen-runtime/checklist.md:276-286`.
- **Medium — direct and multiple-runtime escape:** nothing prevents two runtimes or direct calls from touching one host state. Action definitions are shared process-wide.
- **Medium — standalone integration gap:** `main` keeps a locally scoped runtime alive but exports no runtime handle or producer adapter, and there is no signal integration: `tuna/main.ss:11-31`.
- **Medium — runtime reload remains uncontrolled:** `load-config!` can mutate process-wide live definitions from whichever thread calls it; main only guarantees startup loading before its worker begins: `tuna/lib/config.ss:29-41`; `tuna/main.ss:14-23`.
- **Medium — regression coverage gap:** the tracked Tuna tests cover the command runtime only (`tuna/test/command-runtime-test.ss:115-246`). Completed binding/config/package behavior is primarily roadmap evidence and executable examples, not a consolidated current regression suite.
- **Medium — roadmap provenance:** `plans/emacsen-runtime/checklist.md` and the prior boundary research are untracked in the enclosing Git repository, while Tuna itself is clean and committed.
- **Low — naming collision:** `command-runtime-state` already means lifecycle state (`created/running/stopping/stopped/failed`), so future application-state terminology must remain distinct: `tuna/lib/runtime.ss:51-63`.

## Validation

No tests were executed during this read-only investigation.

Focused current command-runtime validation:

```sh
cd /home/jay/Code/workbench-gerbil/tuna
test/run-command-runtime-matrix.sh
```

This runs the full suite under source `gxi`, normal `gxc`, and `gxc -O`, then verifies checkout status is unchanged: `tuna/test/run-command-runtime-matrix.sh:29-94`.

Broader repository-supported validation:

```sh
cd /home/jay/Code/workbench-gerbil/tuna
gerbil build
gerbil test test/command-runtime-test.ss
test/run-command-runtime-matrix.sh

cd /home/jay/Code/workbench-gerbil/packages/dummy
GERBIL_PATH="$PWD/../../tuna/.gerbil" GERBIL_LOADPATH= gerbil build
```

The build/package commands are documented at `tuna/README.md:42-56`; the M8 test and matrix evidence is recorded at `plans/emacsen-runtime/checklist.md:272-274`. There is currently no single checked-in full suite for all completed M0–M8 behavior.

**Confidence:** high on current code behavior and M8/M9 boundaries; medium on future ownership/publication semantics because the roadmap intentionally defers the host state contract.