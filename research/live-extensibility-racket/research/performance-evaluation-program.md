# Performance and concurrency evaluation program for Tuna live extensibility

## Status and scope

This report designs, but does not execute, an evaluation program for candidate live-extensibility mechanisms. No benchmark, server, package installation, or source mutation was performed.

**Confidence:** high for current Tuna behavior and Racket 9.2 constraints; medium for proposed workloads because the extension API, replacement policy, and performance budgets remain unsettled product decisions.

## 1. Current evidence baseline

### Runtime and package environment

- Tuna requires Racket `base` 9.2, `datastar-lib` 0.4, `web-server-lib` 1.13, and `net-lib`; benchmark/test dependencies are separate (`tuna-racket/packages/tuna/info.rkt:1-12`).
- The active runtime is Racket CS 9.2 (`chez-scheme`, x86_64 Linux).
- Installed package identities observed read-only:
  - `base`: `f902c46d2c95b7e661347fcfd2a37ff0c2b86555`
  - `datastar-lib`: `2389f978f16f279bb39c5ccc3776e17236c91b95`
  - `web-server-lib`: `275c2cd49a3ab2715bb8b36183825d178da8dd9f`
  - `profile-lib`: `8516fcbae4e8370b11746923d71fca99771dff01`
- Exact installed identities should be recorded in every result. Package metadata specifies minimum versions, not an exact environment.

### Racket measurement and concurrency constraints

Official Racket 9.2 documentation supports the following methodology:

- Run timing in plain, non-interactive `racket`; DrRacket instrumentation and surrounding threads can distort results (`racket-doc/scribblings/guide/performance.scrbl:28-49`; [Racket Performance Guide](https://docs.racket-lang.org/guide/performance.html)).
- Direct visible function calls can be inlined, while indirect calls cannot receive all the same optimizations (`performance.scrbl:167-259`). A direct-call control is necessary, but it is not a realistic substitute for live dispatch.
- Mutation may allocate locations and inhibit inlining (`performance.scrbl:263-315`), so allocation must be measured independently of wall-clock time.
- `current-inexact-monotonic-milliseconds` advances with real time within one process but cannot compare different processes directly (`reference/time.scrbl:26-41`).
- `current-process-milliseconds` includes all Racket threads by default and has platform-dependent precision (`reference/time.scrbl:120-149`).
- `current-memory-use 'cumulative` is an estimate of all bytes allocated since startup, including reclaimed bytes (`reference/memory.scrbl:380-419`).
- Mutable hash operations are internally protected as needed, but traversal is not a coherent snapshot and compound operations such as `hash-ref!` are not atomic as a whole (`reference/hashes.scrbl:63-90`).
- Ordinary `thread` creates coroutine threads by default. They share one processor within a place, have sequential consistency, and constant-time Racket operations are normally atomic (`reference/threads.scrbl:39-69`; `reference/eval-model.scrbl:916-955`). Parallel-thread and cross-place results are outside Tuna’s accepted publication guarantee (`eval-model.scrbl:973-1009`).
- Parameters inherit into child threads and follow continuations (`reference/parameters.scrbl:12-31,58-86`). Non-preserved thread cells instead reset to their default in a child (`reference/thread-cells.scrbl:6-20,35-48`).
- Semaphores provide reliable, fair synchronization; `call-with-semaphore` also imposes continuation semantics (`reference/semaphores.scrbl:6-17,73-86`).

### Existing benchmark practice

Tuna currently maintains:

1. **Keymap scaling:** three samples, bounded warmup, median reporting, correctness checks on every iteration, and monotonic elapsed time (`tuna-racket/benchmarks/keymap.rkt:36-90`; `benchmarks/README.md:3-21`).
2. **Live bindings:** five samples, 1/2/4/8 coroutine threads, 30-second worker bounds, explicit writer/reader overlap, per-read generation validation, and separate cumulative-allocation runs (`benchmarks/live-bindings.rkt:6-38,79-185,187-292`; `benchmarks/README.md:23-35`).

The retained live-binding result reports, on its pinned machine:

- stable callable cell: about 8.5 ns/read and effectively zero measured allocation;
- direct global value: about 60 ns/read;
- callable alias: about 382 ns at one thread, rising above 1.2 μs with multiple readers;
- independent context-local reads: about 447 ns;
- shared contexts retain scoped semaphore contention;
- alias paths retain registry-lock contention and roughly 2.3–2.4 KB estimated allocation per read.

These are diagnostic results, not portable thresholds (`benchmarks/live-bindings-results.md:3-20,39-70,72-105`). The reported 0.6 ns direct-call control is likely highly optimized and should not be treated as an attainable live-dispatch target.

## 2. Current hot paths and invariants

### Live callable dispatch

- Callable and value registries are mutable `hasheq` tables with stable cells and one immutable complete generation per cell (`tuna-racket/packages/tuna/bindings.rkt:54-123,414-457`).
- Stable non-alias callable reads avoid Tuna’s structural lock; aliases restart under it (`bindings.rkt:86-94`).
- `function-cell-ref` reads the latest generation, while `function-ref` captures the current implementation (`bindings.rkt:211-225`).
- Actions and transitions snapshot one coherent generation before invoking extension code outside the lock (`bindings.rkt:268-327`).
- The command owner resolves the named action or transition after dequeue (`private/runtime.rkt:622-669`).
- Rendering explicitly captures one live renderer generation before entering extension code (`private/render-support.rkt:61-70`).

**Primary concerns:** single-call latency and allocation; alias/structural-lock contention; preservation of coherent generations during redefinition.

### Hooks and listener iteration

The existing event facility:

- stores an ordered listener list behind a semaphore;
- adds with duplicate scan plus `append`;
- removes with scan plus `filter`;
- snapshots the list under lock, then invokes callbacks outside it;
- performs live lookup for named listeners on each dispatch;
- propagates the first arbitrary failure and skips later listeners.

Evidence: `packages/tuna/event.rkt:11-81`; semantics are tested at `packages/tuna/tests/event-test.rkt:18-72`.

**Complexity:** dispatch O(listeners), add/remove O(listeners), named callback dispatch includes live registry lookup. Ordering, snapshot behavior, and failure policy dominate micro-optimizations.

### Values and dynamic context

- Direct global reads atomically inspect the published generation.
- Contextual reads acquire only the context semaphore, select local/global location, and validate the root generation; aliases or failed validation fall back under the structural lock (`bindings.rkt:590-646`).
- Explicit contexts use a parameter and therefore inherit into children (`bindings.rkt:753-765`).
- Temporary dynamic values use a non-preserved thread cell, `assq` over a dynamic stack, and `dynamic-wind` for unwind (`bindings.rkt:429-439,484-508,808-824`).

**Primary concerns:** lookup latency grows with dynamic depth; contextual allocation and shared-context contention; inheritance and continuation behavior are correctness requirements.

### Registry discovery and generation ownership

Tuna currently has individual descriptor lookups but no public registry enumeration. Cells intentionally persist for process lifetime, and logical removal installs an unbound generation. The repository calls for immutable registry snapshots without exposing cells or invoking extension code under locks (`TODO.org:460-480`).

Proposed owned generation handles must ensure stale cleanup cannot remove a newer registration (`docs/tuna/profiler-extraction-research.md:463-484`).

**Primary concerns:** snapshot latency/allocation and writer blocking; activation/removal cost; stale-handle correctness. Snapshot speed is administrative, not a primary hot-path concern.

### Runtime publication and contention

- Admission uses a semaphore-protected bounded FIFO (`private/runtime.rkt:267-344`).
- State publication creates one immutable root and iterates all subscriptions under the runtime lock (`private/runtime.rkt:557-572`).
- Subscription removal filters the subscription list (`private/runtime.rkt:461-465,545-555`).
- The single owner serializes all application commands (`private/runtime.rkt:622-669,738-835`).

Existing tests cover bounded FIFO behavior, live replacement, concurrent producers, publication, subscriptions, and shutdown (`tests/runtime-test.rkt:81-165,167-298,300-364`).

**Primary concerns:** aggregate throughput, queue/admission contention, publication cost per subscriber, and tail latency caused by synchronous extension callbacks. More ingress threads cannot provide owner-side parallel throughput.

### Page and route dispatch

HTTP dispatch currently constructs a path list and uses a fixed `cond` over five exact routes, with explicit method precedence, 404, 405, and `Allow` behavior (`private/http.rkt:446-585`). Contract tests fix those semantics (`tests/http-contract-test.rkt:177-239`).

A route registry, prefix mount, or middleware chain would make ordering, safety, response authority, shutdown, and method precedence extension-facing API (`docs/tuna/profiler-extraction-research.md:566-587`).

**Primary concerns:** handler latency/allocation only after exact routing semantics and ownership are preserved.

### Activation, removal, and cleanup

Current host extension configuration is snapshotted at host construction; Tuna does not support live activation/deactivation of a running host. Host cleanup:

- has one cleanup owner;
- makes concurrent callers wait;
- attempts service, server, logging, and lifecycle stages in deterministic order;
- retains the first failure;
- publishes completion to waiters.

Evidence: `private/host.rkt:141-168,181-292,323-409`. Concurrent start/stop and exact failure identity are tested at `tests/private/host-test.rkt:413-520`.

**Primary concerns:** exact ownership, idempotence, deterministic failure precedence, full cleanup after partial activation, and absence of leaked threads/resources. Correctness dominates speed.

## 3. Candidate mechanism options to compare

These are materially different evaluation candidates, not architecture decisions.

| Area | Candidate shapes |
|---|---|
| Callable/advice | Stable cell containing a precomposed immutable wrapper procedure; stable definition plus separately published immutable advice vector composed at call time; explicit before/after hook boundaries without general around advice |
| Hooks | Existing semaphore/list snapshot; atomically published immutable vector; keyed immutable map plus separately maintained ordered vector |
| Registry snapshots | Mutable registry copied under structural lock; copy-on-write immutable registry root; mutable authority plus cached immutable descriptor snapshot rebuilt on activation |
| Generation pinning | Capture one generation object at operation entry; `(cell, generation)` identity token validated at selected boundaries; immutable registry-root token covering multiple contributions |
| Dynamic context | Existing parameter plus non-preserved thread-cell stack; explicit immutable context argument; parameter carrying an immutable context map |
| Routes | Exact `(method,path)` immutable lookup; exact path registry with method table; prefix-mounted sub-handler; whole-handler middleware |
| Cleanup | Reverse-order ownership stack; generic named lifecycle stages; dependency graph/topological cleanup |

A mechanism should not be selected solely from microbenchmark results. Around advice, route middleware, dynamic-context inheritance, and cleanup ordering change authority and semantics.

## 4. Measurement matrix

| Mechanism | Latency | Throughput | Allocation | Contention | Correctness priority |
|---|---|---|---|---|---|
| Live function dispatch | Primary | Secondary | Primary | Registry/alias readers | Coherent latest generation |
| Advice chains | Primary by depth | Primary on owner path | Primary | Redefinition versus calls | Order, inverse removal, exception/result behavior |
| Hook iteration | Per dispatch | Calls/second | Snapshot/callback overhead | Add/remove versus run | Snapshot order and failure policy |
| Registry lookup | Primary | Lookups/second | Expected near zero | Readers versus writer | No mixed structure |
| Registry snapshot | Total snapshot time | Snapshots/second | Bytes/entry | Writer hold time and reader tails | Detached immutable result |
| Generation pinning | Per operation and validation | Operations/second | Token/map cost | Redefinition races | One admitted coherent generation |
| Dynamic context | Enter/exit and lookup | Operations/second | Per extent/read | Shared context | Unwind, continuation, child inheritance |
| Page/route dispatch | Handler latency | Requests/second in pure handler | Per dispatch | Registry mutation versus lookup | 404/405, method precedence, response authority |
| Activation/removal | Administrative latency | Churn/second | Per registration | Concurrent owners | Stale handle cannot revoke newer work |
| Cleanup | Total shutdown latency | Not meaningful | Temporary retained memory | Concurrent stop callers | Exact-once cleanup and first-failure identity |

## 5. Proposed bounded microbenchmarks

All benchmark programs should remain separate from RackUnit behavior tests. No benchmark should become a nanosecond assertion.

### MB-1: Live dispatch and generation pinning

**Controls**

1. Empty integer recurrence loop.
2. Direct module-visible procedure.
3. Captured procedure returned by `function-ref`.
4. Current stable `function-cell-ref` wrapper.
5. Name lookup plus call.
6. Callable alias depths 1, 2, 4, 8, and 16.

**Candidate workloads**

- No advice and advice depths 1, 2, 4, 8, and 16.
- Before-only, after-only, and around advice.
- One lookup/call versus 4 and 16 calls under one pinned generation.
- No writer; writer replacing the base definition every 10, 100, or 1,000 reader calls.
- 1, 2, 4, and 8 ordinary coroutine readers, with independent and shared names.

**Correctness assertions**

- Deterministic checksum prevents dead-code elimination.
- Every result is from one admitted generation.
- Advice order is exact.
- Around advice invokes the base exactly once unless the candidate explicitly grants skip/repeat authority.
- Redefinition changes the base seen by subsequent operations.
- A pinned operation remains internally coherent.
- Removing old advice cannot remove a newer same-key generation.

**Outputs:** elapsed and CPU ns/call, calls/second, bytes/call, GC time, writer publications/second, and reader progress/fairness.

### MB-2: Hook iteration and mutation

**Controls**

- Empty dispatch.
- Existing `tuna/event` with procedure listeners.
- Existing event with named listeners.
- Candidate immutable-vector snapshot.

**Matrix**

- 0, 1, 2, 4, 8, 16, 64, and 256 listeners.
- Direct/named mixes of 100/0, 50/50, and 0/100.
- Dispatch only.
- One add/remove per 10, 100, or 1,000 dispatches.
- 1/2/4/8 dispatchers with one mutator, both shared-event and independent-event cases.

**Correctness assertions**

- Exact order and invocation count.
- Duplicate policy.
- Mutation during dispatch affects only the next snapshot.
- Removed listener is not resurrected.
- Failure stops or isolates later callbacks according to the candidate’s declared hook type.

Measure normalized marginal cost per no-op listener as well as total dispatch cost. Callback work should also be repeated with a small realistic payload so an empty lambda does not overstate framework overhead.

### MB-3: Registry lookup and snapshots

**Matrix**

- Registry sizes: 16, 256, 4,096, and 65,536 interned names.
- Hit at stable key, miss, alias depth, descriptor lookup, full descriptor snapshot.
- Snapshot representations: immutable hash, sorted immutable vector, and cached immutable root where implemented.
- One writer at 0%, 0.1%, 1%, and 10% of operations.
- 1/2/4/8 readers, independent and shared keys.

**Correctness assertions**

- Snapshot is detached and immutable.
- Snapshot contains exactly one descriptor generation per admitted key.
- No callback runs under the structural lock.
- Concurrent activation exposes only old or new complete snapshots.
- Logical removals follow the declared enumeration policy.
- Interned-name/cell growth is reported; benchmark names must be preallocated rather than generated without bound.

**Outputs:** lookup ns/op, snapshot total time and bytes/entry, activation time, maximum writer hold duration, reader throughput, and per-worker progress.

### MB-4: Dynamic context

**Controls and candidates**

- Explicit argument.
- Parameter read.
- One `parameterize` extent.
- Existing `call-with-value-context`.
- Existing `call-with-value` thread-cell stack.
- Immutable context-map lookup where proposed.

**Matrix**

- Dynamic nesting depths 0, 1, 4, 16, and 64.
- One versus 16 reads per dynamic extent.
- Local hit, global fallback, and automatically-local write.
- Independent versus shared value contexts at 1/2/4/8 threads.

**Correctness assertions outside timing**

- Normal return, exception, escape continuation, and re-entry restore values.
- Parameter contexts inherit into child threads.
- temporary dynamic values do not inherit.
- local hide/reveal and aliases preserve location identity.

The existing behavior tests at `bindings-test.rkt:286-396,494-626,710-748` are the semantic baseline.

### MB-5: Pure page and route dispatch

Do not start a server. Construct synthetic `web-server/http` requests and call handlers directly, as current HTTP contract tests do.

**Controls/candidates**

- Current fixed `cond`.
- Exact immutable route hash.
- Path registry plus method table.
- Prefix mount.
- Middleware chain depths 0, 1, 4, and 16.

**Matrix**

- 5, 32, 128, and 1,024 routes.
- First/middle/last hit, miss, wrong method, parameterized-path rejection.
- Static bytes response, small dynamic response, and page assembly with 0/1/4/16 contributions.
- Registry replacement every 100 or 1,000 dispatches.

**Correctness assertions**

- Exact 200/204/404/405 behavior.
- Method checks precede extension enablement where currently required.
- Exact `Allow`, cache, and content-type headers.
- No broader prefix capture than declared.
- Stale route handle cannot remove its replacement.
- Trusted response authority remains explicit.

Measure path extraction separately from registry lookup so URL/request construction does not hide router cost.

### MB-6: Activation, removal, and cleanup kernels

**Matrix**

- 1, 16, 64, and 256 contributions.
- Initial activation, same-owner replacement, foreign conflict, stale removal, current removal, repeated removal.
- Partial activation failure at first/middle/last resource.
- Cleanup success and failure at first/middle/last resource.
- 1/2/4/8 concurrent activation/removal or stop callers using deterministic semaphore barriers.

**Correctness assertions**

- Every published resource has cleanup authority before an interruptible checkpoint.
- Rollback is reverse order unless another explicit contract is chosen.
- Every cleanup stage is attempted.
- First failure identity is retained.
- Cleanup is exact-once; stale handles are no-ops or explicit errors according to the declared policy.
- All waiters terminate with the correct result.
- Owned thread/resource counts and weak-box reachability return to baseline.

Administrative timing is characterization only. A faster mechanism that leaks or changes failure precedence fails.

## 6. Functionality spikes before performance selection

Each spike should use temporary or explicitly approved test-only source, deterministic semaphores instead of sleeps, a 10-second worker bound, and at most four worker threads.

### Spike A: Owned registration kernel

Implement the smallest private model supporting keyed registration, owner identity, generation replacement, immutable snapshot, and idempotent revocation.

Exercise:

- duplicate and foreign-owner behavior;
- stale handle after replacement;
- concurrent snapshot versus replacement;
- partial activation rollback;
- no callbacks under registry locks.

This resolves representation feasibility before benchmarking all host machinery.

### Spike B: Advice/redefinition composition

Wrap one live callable with two named advice contributions, redefine the base, remove advice in both orders, and verify the latest underlying definition remains visible. Force base and advice failures to establish result and exception precedence.

If this cannot be specified without granting uncontrolled skip/repeat authority, stop the general-advice candidate and evaluate declared lifecycle hooks instead.

### Spike C: Command observer integration without profiler concepts

Use the existing runtime’s pure test seam, not HTTP or a server. Register two materially different observers, such as a counter and an audit recorder. Exercise admission, dequeue, success, application failure, changed publication, completion, stop, and observer removal.

Assertions:

- command result/failure identity is unchanged;
- all terminal paths notify according to policy;
- advisory failure is retained but fail-open if that policy is selected;
- no observer executes under runtime locks;
- owner liveness and accepted-prefix draining remain intact.

### Spike D: Dynamic routes and page contributions

Build a pure handler around synthetic requests. Activate an exact route and page contribution, replace it, invoke an in-flight handler while removing the registration, and then clean up.

Preserve all route/header assertions from `http-contract-test.rkt:177-239,342-420`.

### Spike E: Host lifecycle integration with fakes

Use parameterized fake service/start/stop operations already established in `private/host-test.rkt`, never a real server. Force:

- activation failure after one resource;
- stop racing activation;
- two concurrent stop waiters;
- cleanup failure plus later successful cleanup attempts;
- stale cleanup after reactivation.

The spike succeeds only if every owner terminates and exact first-failure semantics remain deterministic.

## 7. Iteration, warmup, and reporting policy

### Preflight

1. Run each candidate’s behavior assertions once outside timing.
2. Run a 10–100 ms calibration pilot.
3. Select an iteration count targeting 250–750 ms per measured batch.
4. Cap a batch at 10 million operations and 30 seconds.
5. Abort rather than silently changing workload when calibration cannot fit bounds.

### Samples

- Two unreported warmup batches per case.
- Ten measured batches for ordinary characterization.
- For close paired comparisons, use 15 deterministic alternating A/B pairs, matching Tuna’s prior alias crosscheck.
- Run candidates sequentially, never concurrently with another benchmark variant.
- Randomize case order with a recorded fixed seed, except alternating A/B pairs.
- Run allocation cases separately and single-threaded unless allocation under contention is the explicit subject.
- Force two major collections before allocation batches, matching the maintained benchmark. For latency batches, record GC time during the batch rather than subtracting it.

### Timing controls

- Record monotonic elapsed time and process CPU time.
- Include an empty-loop and clock-only control.
- Report controls separately; do not silently subtract them.
- Consume a returned checksum after the timed loop.
- Do not allocate a result list per operation merely to preserve observations.

### Allocation and retention

- Use `current-memory-use 'cumulative` around prewarmed batches for bytes/op estimates.
- Record raw cumulative deltas and control deltas.
- For lifecycle retention, create a dedicated custodian where feasible, force collections, and report reachable memory plus weak-box/resource assertions.
- Allocation estimates must be labeled estimates, as Racket documents.

### Concurrency reporting

Because these are ordinary coroutine threads:

- report aggregate operations/second and per-worker completed operations;
- report batch elapsed distribution and writer progress;
- do not claim multicore scaling;
- distinguish independent registries/contexts from intentionally shared locks;
- never extend the conclusion to parallel threads or places.

### Result record

Retain machine-readable raw rows and a Markdown summary containing:

- repository commit and dirty state;
- exact command and `PLTCOLLECTS`;
- Racket version, VM, garbage collector, architecture, OS/kernel, CPU;
- exact installed dependency identities;
- seed, warmups, iterations, sample count, timeouts;
- median, p05, p95, median absolute deviation, minimum, and maximum;
- ns/op, operations/second, bytes/op, CPU and GC time;
- correctness checksum and worker cleanup result;
- all timeouts, rejected samples, and reasons.

No outlier should be deleted silently. A noisy case should be rerun after environmental review or reported inconclusive.

## 8. Stop and decision criteria

### Immediate correctness stop

Stop a candidate’s evaluation on any:

- mixed generation or incoherent snapshot;
- stale handle removing newer work;
- callback under a structural/runtime lock;
- changed command result or failure identity from advisory instrumentation;
- lost terminal notification;
- broken route/method/header precedence;
- failed unwind, continuation, or child-thread context rule;
- cleanup omission, double cleanup, leaked owner/waiter, or nondeterministic first-failure result.

Speed cannot compensate for these failures.

### Bounded-execution stop

- 30 seconds per batch or worker synchronization.
- Ten minutes per microbenchmark family.
- One hour for the complete characterization run.
- Stop and retain partial output if a budget is exhausted.
- Any forced cleanup is a benchmark-harness failure, not a successful sample.

### Complexity stop

Investigate or stop when observed scaling contradicts the representation:

- direct dispatch or exact hash lookup grows materially with total registry size;
- snapshot growth is worse than linear in entries;
- advice/hook marginal cost accelerates beyond linear depth without a documented cause;
- independent readers degrade like shared-lock readers;
- cleanup or removal becomes quadratic where no semantic requirement demands it.

These are scaling-shape gates, not fixed nanosecond thresholds.

### Variability and selection

- If median absolute deviation exceeds 10% of the median in two runs, classify the case as inconclusive rather than selecting a winner.
- Performance acceptance budgets for owner-path overhead, route latency, or activation time must be set by the owner before results are used as pass/fail gates.
- Before those budgets exist, report relative deltas and scaling only.
- A candidate with a microbenchmark advantage must still pass the runtime and lifecycle spikes.
- A full HTTP throughput or p50/p95/p99 latency claim requires a separately authorized bounded server benchmark; pure handler results cannot establish it.

## 9. Where correctness dominates speed

1. **Generation coherence:** actions bundle implementation, host descriptor, acquirer, and documentation. Splitting them for speed is unacceptable.
2. **Advisory failure isolation:** observer speed is secondary to preserving command results, publication, and infrastructure failure identity.
3. **Dynamic scope:** parameter inheritance, thread-cell noninheritance, continuation re-entry, and unwind semantics define behavior.
4. **Routes:** 404/405 precedence, exact method/path ownership, request bounds, and cleanup are security and API contracts.
5. **Activation/removal:** generation ownership and stale cleanup are more important than administrative latency.
6. **Cleanup:** all stages, exact-once ownership, accepted-prefix draining, and deterministic first failure dominate parallel or faster shutdown.
7. **Single-owner runtime:** extension callbacks must not compromise FIFO execution, bounded admission, or liveness.

## 10. Risks and unresolved gaps

- Registration replacement, ordering, route authority, advice authority, and hook failure policies remain product/API decisions. The benchmark program must not decide them.
- Tuna currently has no live running-host activation protocol, route registry, registry enumeration API, or advice implementation. Candidate microbenchmarks will initially measure kernels, not production integration.
- Existing live-binding results predate the current `4df523c` commit label in their environment section; rerun the unchanged benchmark as a fresh control before comparing new mechanisms.
- The existing direct-call control is vulnerable to compiler inlining and constant folding. New controls need a nontrivial consumed checksum.
- Coroutine contention results characterize Tuna’s accepted ordinary-thread model, not multicore scalability.
- Pure route tests omit TCP, web-server, Datastar, browser, and Server-Sent Event costs.
- Registry cells and interned symbols intentionally persist. Benchmarks must not generate unlimited names and mistake intentional authority retention for a leak.
- Snapshot and cleanup memory assertions require careful reachability controls; official Racket documentation warns weak-box tests can pass if the enclosing owner itself becomes unreachable (`performance.scrbl:639-676`).
- General callable advice remains high risk and may be unnecessary if declared command/publication/delivery hooks satisfy the non-profiler use cases (`docs/tuna/profiler-extraction-research.md:589-605,630-650`).

## 11. Candidate validation commands

These are evidence-backed future commands, not commands executed during this research:

```sh
cd /home/jay/Code/workbench-racket/tuna-racket

# Existing behavior baselines
PLTCOLLECTS="$PWD/packages:" raco test \
  packages/tuna/tests/bindings-test.rkt \
  packages/tuna/tests/event-test.rkt \
  packages/tuna/tests/runtime-test.rkt \
  packages/tuna/tests/private/runtime-fault-test.rkt \
  packages/tuna/tests/private/subscription-break-test.rkt \
  packages/tuna/tests/private/host-test.rkt \
  packages/tuna/tests/http-contract-test.rkt

# Existing integration/lifecycle baselines; bounded process tests only when authorized
PLTCOLLECTS="$PWD/packages:" raco test \
  tests/integration/counter-dispatch-test.rkt \
  tests/process/server-lifecycle-test.rkt \
  tests/process/sse-lifecycle-test.rkt

# Existing maintained performance controls; run separately, never concurrently
PLTCOLLECTS="$PWD/packages:" racket benchmarks/live-bindings.rkt
PLTCOLLECTS="$PWD/packages:" racket benchmarks/keymap.rkt
```

New performance programs should be split by family so each has an independent timeout and can retain partial raw results.