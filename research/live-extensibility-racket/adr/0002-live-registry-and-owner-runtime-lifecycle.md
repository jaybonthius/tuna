# ADR 0002: Live registry and owner-runtime lifecycle

Status: accepted — owner-chat-2026-08-05: accept-adr-set-and-start-slice-1

## Context

Tuna needs live replacement across compiled callers, independent callable/value domains, coherent action generations, dynamic and context-local values, bounded command admission, one sequential state owner, exact request completions, coalesced subscriptions, and deterministic shutdown. HTTP 204 admission also requires bounded ownership of completion observation. These obligations must compose without callbacks under structural locks, hidden lifecycle threads, accepted-but-unobserved work, or discarded observer diagnostics.

## Decision

### Live registries and value locality

Use separate semaphore-protected mutable `hasheq` registries for callable and value names. Lookup-or-create publishes one stable private cell per interned name; cells are never removed, and logical removal installs an unbound sentinel. Each callable cell publishes one opaque immutable generation whose variant structurally distinguishes function, action, transition, alias, and unbound state. Action body, host descriptor, acquirer, and documentation are one coherent generation. Value cells similarly preserve root and alias identity.

Structural publication and alias traversal remain synchronized; application procedures, acquirers, transitions, listeners, and descriptor consumers run after locks are released. Established non-alias readers atomically snapshot the cell's one complete immutable generation without acquiring the registry-wide structural semaphore. Callable aliases restart under that semaphore. Contextual value reads use the existing context semaphore to select and read the local/global location, then validate that the root generation is still the initially observed object; aliases and validation failures restart once through the structurally locked path. This amendment relies on Racket 9.2 ordinary coroutine threads' sequential consistency and atomic constant-time field operations. It makes no parallel-thread or cross-place publication guarantee.

No multi-name transaction is promised. Definition-site wrappers read the current generation on every call; `function-ref` captures the current implementation. Aliases point to stable cells and detect cycles by identity. Public descriptors are detached immutable snapshots, and mutable documentation input/output is copied.

Use a non-preserved thread cell plus `dynamic-wind` for `call-with-value`, so temporary bindings unwind safely and are not inherited by child threads. Use a guarded parameter for continuation-safe, child-inherited selection of an explicit context object. Each context owns synchronized stable local cells keyed by resolved value-root identity. Every value operation re-resolves aliases and selects the active local/global location on each call, preserving location-based hide/reveal behavior.

### Application owner and synchronization

One tracked ordinary Racket thread is the sole application/state owner. Producers use a semaphore-protected bounded FIFO and receive only `accepted`, `full`, or `not-running`. No per-request worker exists. A coalesced binary owner-wake semaphore is posted on empty-to-nonempty and stop; the owner drains until empty, then atomically rechecks queue and lifecycle state before waiting. Wake consumption and wait/state transitions are break-safe.

Requests retain names; after dequeue the owner snapshots one complete live generation. Nested submission by the owner is rejected. Completions are helper-thread-free single-assignment cells with immutable observations and a readiness semaphore; store precedes post. Subscriptions use explicit `pending?`, `closed?`, latest hint, and a semaphore. Publication coalesces without blocking, waiters reread the latest immutable `(revision value provenance)` root, and break handling preserves pending-before-EOF. No lifecycle-bearing `racket/async-channel` is used.

Only the owner installs a changed root. Root publication and subscription invalidation happen before request completion. Normal stop closes ingress, fixes and drains the accepted prefix, closes subscriptions, and joins the application owner and every explicitly owned observer/sink/stream resource before any custodian fallback. Cleanup attempts all stages and preserves the first failure; kill, break, and custodian shutdown are not the normal protocol.

The accepted correction is exact:

> `owner-chat-2026-08-05: complete-current-on-owner-failure` corrects a pinned runtime edge that can leave a dequeued accepted request waiting forever. The port must conditionally fail a still-pending current completion with the original infrastructure reason; an already completed current observation remains unchanged. Abnormal join raises an uncaught-owner wrapper containing the infrastructure reason.

Queued pending completions receive that same original infrastructure reason. Ordinary application failure completes only its request and does not terminate the owner.

### Private WEB-04 completion observation

For runtime queue capacity `N`, the private service owns exactly `N + 1` preallocated opaque observer slots: at most one owner-current command plus `N` queued commands. Slot state is synchronized and moves only `free → reserved → registered/observing → free`. One tracked completion-observer owner starts before the runtime; HTTP ingress opens only after both owners exist.

The service ingress lock linearizes admission and stop. A decoded POST must reserve a slot nonblockingly before runtime submission. Exhaustion returns `full` without submission. Runtime `full`, `not-running`, raised pre-acceptance failure, stop-winning, or any other non-accepted path rolls the reservation back exactly once.

After runtime acceptance, the reservation is already owned. In one break-disabled service transition, store the completion in the slot, append that slot once to the bounded observer FIFO, and signal the observer. Registration performs no capacity acquisition and cannot reject accepted work. Only after registration may service admission return `accepted`, and only then may HTTP emit 204.

The sole observer drains registered slots FIFO, waits on helper-thread-free completions outside service/runtime locks, consumes success or arbitrary failure, and reports command failure through contained logging. An exact-once cleanup guard returns the slot even when completion observation or failure logging raises. Every observer-only completion-observation or failure-logging fault is contained from the application owner **and retained as a lifecycle diagnostic**; it is not silently discarded or allowed to replace the command result. Slot release remains exactly once, and the application owner continues processing later work.

Stop closes service ingress and fixes the accepted/registered prefix, drains/joins the runtime, closes and drains the observer FIFO, joins the observer, and requires all slots free before successful lifecycle completion. Retained observer lifecycle diagnostics remain inspectable/reportable at the lifecycle boundary without changing the application owner's result or liveness.

This protocol constrains behavior and ownership only. It does not expose a public service/observer module layout, preserving `RUN-09` freedom to choose any cohesive private decomposition.

## Rejected alternatives

- Ordinary module rebinding or copied implementations: compiled callers would not remain live.
- Split mutable generation fields or separate kind flags: readers could observe mixed generations or kinds. One atomic field containing one complete immutable generation is accepted for ordinary Racket threads; stronger parallel-thread publication remains out of scope.
- One parameter for both dynamic bindings and contexts: child inheritance is wrong for `call-with-value`.
- Synchronous channels, lifecycle-bearing async channels, per-request workers, or completion waiter threads: they violate bounded admission, single ownership, or deterministic join.
- Separate revision/value publication or snapshot-then-subscribe: readers can observe mixed roots or miss a wake.
- Forced kill/break/custodian shutdown as normal stop: accepted work and completions can be stranded.
- Observer reservation after runtime acceptance or after HTTP 204: creates accepted-but-unobserved work and unbounded failure-observation pressure.
- Logging and discarding observer faults: loses required lifecycle diagnostics even if capacity is recycled.
- Reproducing Gerbil's exact private service decomposition: private representation parity is not required.

## Consequences

### Behavioral and public

Compiled wrappers remain live while explicit snapshots remain stable. Callable/value names coexist independently; action fields are coherent; aliases and context/local/dynamic behavior follow stable root/location identity. Admission is bounded and nonblocking, application execution is FIFO and single-owner, changed state publishes before completion, subscriptions coalesce, and every accepted request receives exactly one terminal observation, including infrastructure failure.

WEB-04 204 means accepted command plus published observer registration, not command success. Runtime or observer saturation and all non-accepted results map to 503 without waiting for completion.

### Security, lifecycle, and concurrency

Locks protect structure and publication only; user/extension code never runs under them. Break-disabled intervals are limited to wake/state and accepted-registration transitions. All owner, observer, completion, subscription, logging, and stream resources have explicit ownership and deterministic close/drain/join. Observer-only observation/logging faults are retained as lifecycle diagnostics, do not kill the application owner, and do not leak or double-release slots. Mutable application roots remain immutable-by-contract rather than deep-frozen.

## Validation obligations

Public and deterministic private tests must cover stable single-cell authority, complete old/new generations, aliases/cycles, dynamic unwind/noninheritance, inherited contexts and hide/reveal, burst admission under one wake, drain/rearm and stop wake, FIFO/dequeue-time lookup, publication-before-completion, exact-once arbitrary-value completion, breaks around waits, pending-before-EOF, and no helper/owner leaks.

Fault tests must force owner failure before, during, and after publication; prove pending-current and queued exact reason identity, completed-current preservation, conditional-current no-op followed by queued draining, and abnormal wrapper reason identity. WEB-04 tests must fill all `N + 1` slots, prove the next request is not submitted, exercise every rollback and stop/admission boundary, prove registration-before-204, observe/log application failure while later work proceeds, and finish with every slot free, one observer joined, one application owner joined, and no per-request/orphan thread.

A deterministic observer-fault test must separately inject a completion-observation fault and a contained failure-logging fault and prove in each case that: the exact fault is retained as a lifecycle diagnostic; the affected slot returns to `free` exactly once; no other slot is released; later accepted work is executed by the still-running application owner; and shutdown joins both owners with all slots free.

## Traceability

- **Baseline IDs:** `LIVE-01`–`LIVE-13`, `RUN-01`–`RUN-09`, `EVT-01`, `WEB-04`.
- **Matrix pattern IDs:** `LIVE-01a`, `LIVE-01b`, `LIVE-02`, `LIVE-03a`, `LIVE-03b`, `LIVE-04`, `LIVE-05`, `LIVE-06`, `LIVE-07a`, `LIVE-07b`, `LIVE-08`, `LIVE-09`, `LIVE-10`, `LIVE-11a`, `LIVE-11b`, `LIVE-12a`, `LIVE-12b`, `LIVE-13a`, `LIVE-13b`, `LIVE-13c`, `RUN-01`, `RUN-02`, `RUN-03`, `RUN-04`, `RUN-05`, `RUN-06`, `RUN-07`, `RUN-08`, `RUN-09`, `EVT-01`, `WEB-03/04`.
