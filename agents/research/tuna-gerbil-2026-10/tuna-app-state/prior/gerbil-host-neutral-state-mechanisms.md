# Gerbil v19/Gambit mechanisms for host-neutral authoritative state

## Executive findings

For a long-lived extensible program, the strongest generic architecture available in the installed Gerbil v19 is a **single named owner thread receiving commands through a positive-capacity bounded `:std/sync/channel`**. Keep authoritative state as a revisioned root value, preferably treated as immutable, and return results through per-command completions or one-slot reply channels.

This avoids shared mutation races and makes command ordering, failure containment, and revision assignment explicit. It does not depend on HTTP, rendering, or any particular application domain.

Important constraints:

1. The installed runtime is `v0.19-dev-31-g4a4d1a30` on Gambit `v4.9.7-6-g64f4d369`, with Symmetric Multiprocessing (SMP) disabled. `gerbil-runtime-smp?` returned `#f`; detection is based on `--enable-smp` in the configure command (`gerbil-dev/src/gerbil/runtime/system.ss:61-67`).
2. Gambit nevertheless specifies that unsynchronized concurrent reads and writes to the same store location are erroneous (`gerbil-dev/src/gambit/doc/gambit.txi:10045-10053`). Designs should not rely on the current single-virtual-processor build to excuse missing synchronization.
3. Gerbil structs, classes, lists, vectors, boxes, and hash tables are mutable unless the application enforces an immutable-use convention. `final: #t` prevents subclassing; it does not freeze fields.
4. Gerbil v19 does not include a supported persistent map/set library comparable to a Hash Array Mapped Trie (HAMT). SRFI 146 and its HAMT implementation exist only under `src/v0.19-WIP/v0.19-TODIE-*` and imports fail.
5. The documented v0.18 `:std/actor` and ensemble supervisor are unavailable in the installed v19. The current `:std/ensemble/actor` is a different, distributed abstraction whose message handlers run concurrently and therefore do not serialize an actor’s mutable state.

## Runtime baseline and source status

- Installed tool: `Gerbil v0.19-dev-31-g4a4d1a30 on Gambit v4.9.7-6-g64f4d369`.
- Repository `gerbil-dev` is one commit newer, `v0.19-dev-32-g4531c21b`; its generated Gambit C files were already dirty.
- The installed and `gerbil-dev` versions of `std/sync/atom.ss`, `rwlock.ss`, and `channel.ss` are byte-identical.
- The installed build uses `--enable-single-host` but not `--enable-smp`; runtime detection is documented at `gerbil-dev/doc/reference/gerbil/runtime/system-information.md:18-23`.

Gambit threads share one object space (`gerbil-dev/src/gambit/doc/gambit.txi:9854-9869`). On this build they provide scheduling concurrency and I/O overlap, not multicore Scheme execution. The Gambit manual’s statement that at most one thread runs matches this installation (`gerbil-dev/src/gambit/doc/gambit.txi:9826-9830`).

## Mechanism semantics and tradeoffs

### 1. One-owner thread and raw mailbox

`spawn/name` creates and immediately starts a named Gerbil actor thread (`gerbil-dev/src/gerbil/runtime/thread.ss:27-54`). These “actor threads” are still ordinary in-process threads with two additions:

- an abortive unhandled-exception handler that unwinds finalizers;
- efficient thread-local storage.

This contract is documented at `gerbil-dev/doc/reference/gerbil/runtime/thread-primitives.md:1-24` and implemented at `gerbil-dev/src/gerbil/runtime/thread.ss:43-81`.

Every Gambit thread has a mailbox. `thread-send` appends messages, and delivery order is FIFO in the order messages reach the mailbox (`gerbil-dev/src/gambit/doc/gambit.txi:10518-10536`). `thread-receive` supports relative/absolute timeout and a default result (`gerbil-dev/src/gambit/doc/gambit.txi:10540-10564`).

**Benefits**

- Minimal runtime surface.
- Natural single-writer state ownership.
- Per-producer program order is straightforward; the owner creates one total processing sequence.
- No application-state mutex is needed.

**Constraints**

- The mailbox has no documented capacity or backpressure.
- It has no channel-like close/EOF operation.
- Cross-producer arrival order depends on scheduling and is not a global causal ordering guarantee.
- Retain the owner’s thread handle: `thread-join!` is the failure-observation mechanism.

Raw mailboxes are suitable only when admission is bounded elsewhere.

### 2. Bounded channels

The active module is `:std/sync/channel`; documentation still incorrectly names `:std/misc/channel`, which fails to import.

A channel contains a queue, mutex, condition variable, optional fixnum limit, and close flag (`gerbil-dev/src/std/sync/channel.ss:15-28`).

Semantics:

- `channel-put` blocks or times out when the queue is at its limit; it returns `#t` on admission and `#f` on timeout (`channel.ss:30-47`).
- `channel-try-put` immediately returns `#f` when full (`channel.ss:49-63`).
- Reads are FIFO. `channel-get` supports timeout/default (`channel.ss:77-102`).
- Closing wakes waiters. Existing queued values drain before readers receive `#!eof` (`channel.ss:83-95,101-127`).
- Puts after close raise an I/O-closed error (`channel.ss:35-37,52-54`).

Performance-relevant constraints:

- Every ordinary put/get acquires the channel mutex and may broadcast its condition variable.
- A positive limit is required for a useful bounded queue. The constructor does not validate the limit; zero creates a channel in which ordinary puts can never enqueue, without rendezvous semantics.
- **Do not use `channel-sync` as bounded admission.** It enqueues every supplied value without checking `limit` (`channel.ss:65-75`).
- `channel-closed?` reads the close flag without locking, and `channel-close` checks it before locking (`channel.ss:117-127`). This is not a demonstrated defect on the current SMP-disabled runtime, but it conflicts with Gambit’s general memory-coherency rule and requires re-audit before SMP deployment.

For a state owner, use a positive bounded capacity and only `channel-put`/`channel-try-put` for command admission.

### 3. Completions

The active module is `:std/sync/completion`; the documented `:std/misc/completion` import is stale.

A `Completion` holds a mutex, condition variable, readiness flag, value, and exception (`gerbil-dev/src/std/sync/completion.ss:15-25`).

- `completion-wait!` waits in a condition loop and either returns the posted value or raises the posted exception (`completion.ss:33-44`).
- Posting is one-shot, wakes all waiters, and duplicate posting raises an error (`completion.ss:46-64`).
- There is no timeout argument to `completion-wait!`.
- `completion-reset!` mutates fields without acquiring the mutex (`completion.ss:27-31`); use it only with exclusive lifecycle control, never concurrently with waiters or posters.
- `completion-ready?` is a raw generated accessor, not a synchronized query.

Use a completion when every accepted command must eventually resolve and caller abandonment is not required. Use a capacity-one reply channel when callers need a timeout. A timed-out caller does not cancel already accepted work; cancellation needs a separate cooperative protocol.

### 4. Atoms

The active module is `:std/sync/atom`; documentation still names `:std/misc/atom`, which fails to import.

An `Atom` holds a mutex, value, validator, and watcher table (`gerbil-dev/src/std/sync/atom.ss:31-36`). All mutations acquire the mutex:

- swap functions execute the transformation under the atom lock (`atom.ss:40-80`);
- reset and identity-based compare-and-set are lock-protected (`atom.ss:82-95`);
- validation happens before assignment;
- watchers execute after assignment while the same lock is held (`atom.ss:45-54,97-105`).

The documentation accurately warns that watches run in unspecified order while the lock is held and must not modify the same atom (`gerbil-dev/doc/reference/std/misc/atom.md:251-279`).

Tradeoffs and hazards:

- Transform functions, validators, and watchers lengthen the critical section. Blocking I/O or callback-heavy logic there blocks all atom mutations.
- Re-entering mutation of the same atom deadlocks because Gambit mutexes are nonrecursive (`gerbil-dev/src/gambit/doc/gambit.txi:9932-9935`).
- A watcher exception occurs after the value has changed. It can prevent later watchers from running and propagate to the modifying caller; therefore watches are not a transactional event system.
- `atom-compare-and-set!` compares by `eq?`, not structural equality (`atom.ss:90-95`).
- There are no multi-atom transactions. Put `(revision, state)` in one root if coherence matters.
- Current transformations do not retry, though the documentation reserves the right to change this (`gerbil-dev/doc/reference/std/misc/atom.md:35-39`).

**Memory-visibility gap:** `atom-deref` is merely the generated `Atom-value` accessor (`atom.ss:16-18,38`); it does not lock. Validators and atom mutations are synchronized, but ordinary dereferences are not. This conflicts with Gambit’s strict rule against read/write races. It is practically less exposed on the current non-SMP runtime, but an Atom should not be treated as a proven SMP-safe publication primitive without upstream clarification or a synchronized getter.

An Atom works well for short, independent, copy-on-write root transitions on this installed runtime. It is a weaker basis than a state owner when transitions can block, require command queues, or need explicit lifecycle and overload handling.

### 5. Atomic counters and revisions

`AtomicCounter` stores a fixnum in a one-element vector and updates it using `##vector-cas!` in a retry loop (`gerbil-dev/src/std/sync/atom.ss:110-125`).

Important semantics:

- `increment-atomic-counter!` returns the **old** value, confirmed by source tests (`gerbil-dev/src/std/sync/atom-test.ss:37-46`).
- It accepts arbitrary fixnum increments, including negative values.
- It uses `fx+`, so it is a fixed-width counter rather than an unbounded integer revision.
- The counter and application state are separate locations; updating both is not an atomic state commit.

For authoritative revisions, the safest generic rule is to construct one new root `(revision, state)` and install it in the same owner operation or locked/atom update. Generic arithmetic can use unbounded exact integers if rollover must not occur. Reserve `AtomicCounter` for independent identifiers or metrics where its old-value return and fixed-width behavior are intentional.

### 6. Mutexes and condition variables

Gambit mutexes are nonrecursive and support owned, not-owned, abandoned, and normal unlocked states (`gerbil-dev/src/gambit/doc/gambit.txi:9911-9938`). `mutex-lock!` supports timeout and raises an abandoned-mutex exception when acquiring an abandoned mutex (`gambit.txi:10765-10799`).

Notably, `mutex-unlock!` permits unlocking an unlocked mutex or one owned by another thread (`gambit.txi:10875-10889`). Ownership is therefore a discipline, not an enforcement boundary.

Condition waits may resume without the desired condition becoming true. Code must reacquire and recheck in a loop (`gambit.txi:10875-10925`).

Gerbil provides:

- `with-lock`: exception-safe unlock, but a continuation escaping its dynamic extent can leave the mutex locked;
- `with-dynamic-lock`: uses `dynamic-wind` and is the continuation-safe alternative.

The warning is explicit at `gerbil-dev/doc/reference/gerbil/runtime/thread-primitives.md:119-140`; implementations are at `gerbil-dev/src/gerbil/runtime/thread.ss:138-158`.

A mutex store is efficient for very short, nonblocking critical sections. Its main architectural cost is distributed mutation ownership: every extension and callback must follow the same lock policy.

### 7. Read-write locks

The active `:std/sync/rwlock` is implemented over one mutex and two condition variables (`gerbil-dev/src/std/sync/rwlock.ss:18-37`).

Semantics:

- Readers enter concurrently only when there is no active writer and no waiting writer (`rwlock.ss:39-48`).
- Once a writer waits, new readers are blocked: the implementation is writer-preferring (`rwlock.ss:42-45,62-75`).
- Unlocking the final reader signals a writer; writer unlock signals another writer before broadcasting to readers (`rwlock.ss:50-86`).
- It tracks only a global reader count and one writer field. It does not track reader ownership, and write unlock checks only whether some writer exists, not whether the current thread is that writer.
- Read/write locks are nonrecursive in practice.
- `with-read-lock` and `with-write-lock` clean up on ordinary return and exceptions (`rwlock.ss:88-126`), but unlike `with-dynamic-lock`, they do not use `dynamic-wind`; escaping continuations remain hazardous.

Performance fit:

- On the current non-SMP build, concurrent readers do not execute Scheme code on multiple cores.
- A read-write lock can help future SMP read-heavy workloads, but adds counters, conditions, and writer-preference scheduling overhead.
- It is inferior to a simple mutex unless read sections are substantial and demonstrably concurrent.
- The upstream RWLock test is disabled by default as “quite flaky” (`gerbil-dev/src/std/sync/rwlock-test.ss:4-7`), reducing confidence compared with channel/atom/completion coverage.

### 8. Mutable and persistent state representations

Gerbil’s standard object facilities provide representation, not immutability:

- Class slots are directly mutable through generated mutators and dynamic `@` assignment (`gerbil-dev/doc/guide/intro.md:431-459`).
- Non-final classes may require dynamic slot lookup; exact/final classes and structs avoid it (`intro.md:461-465`).
- Structs have fixed prefix layouts and direct memory-reference slot access (`intro.md:548-566`).
- Struct positional construction and access are faster than class keyword initialization/dynamic slot lookup (`intro.md:603-616`).
- `final:`, `transparent:`, `equal:`, and `print:` control inheritance, equality, and display—not field mutability (`gerbil-dev/doc/reference/gerbil/prelude/macros.md:431-451`).

There is no installed standard persistent-map API:

- `:std/srfi/146`, `:std/struct/hamt`, and related imports fail.
- HAMT source exists only beneath `gerbil-dev/src/v0.19-WIP/v0.19-TODIE-std/srfi/146/`.

Practical immutable-use options are:

1. Construct new structs/lists for changed paths and never call their mutators after publication.
2. Use association lists for small maps, accepting linear lookup/update.
3. Copy mutable collections before changing them, accepting whole-collection copying.
4. Add a separately vetted persistent-collection dependency rather than relying on v19 WIP source.

Structural sharing is safe only when every shared descendant is also treated as immutable.

### 9. Snapshot and copy strategies

#### Immutable-root handoff

If the entire reachable graph is immutable by convention, handing out the root is O(1). Old readers can retain old roots while the owner publishes a new root. Updates allocate only reconstructed paths when the data model permits manual structural sharing.

This is the fastest read strategy, but Gerbil does not enforce the convention. A leaked box, vector, hash table, class, or struct mutator can corrupt both old and new snapshots.

#### Shallow copies

- `vector-copy` explicitly does not recursively copy elements (`gerbil-dev/src/gambit/doc/gambit.txi:3833-3838`).
- `struct-copy` delegates directly to `##structure-copy` (`gerbil-dev/src/gerbil/runtime/mop.ss:970-971`).
- `hash-copy` delegates to the hash implementation’s `copy` method (`gerbil-dev/src/gerbil/runtime/hash.ss:633-635`).

Installed probes confirmed that `struct-copy` and `hash-copy` preserve references to nested boxes. Shallow copy is appropriate only when nested values are immutable or separately copied.

#### Deep serialization copy

Gambit’s `object->u8vector` followed by `u8vector->object` reconstructs a structurally equal graph (`gerbil-dev/src/gambit/doc/gambit.txi:8958-8973`). A probe confirmed that it produced a distinct nested box while preserving internal sharing.

Tradeoffs:

- O(size of reachable graph) traversal and allocation.
- Some objects—including threads, wills, and some ports—are not serializable.
- Snapshotting must occur in the owner or under a lock; serialization does not make concurrent traversal of a mutating graph safe.
- It is useful for infrequent isolation, checkpointing, tests, or process boundaries, not high-frequency reads.

The current `:std/serde/marshal` also performs binary serialization and supports class filtering and graph options (`gerbil-dev/src/std/serde/marshal.ss:16-35`), but brings a larger evolving v19 surface than the documented Gambit serializer.

### 10. Parameters and thread-local storage

Parameters are dynamic configuration, not authoritative shared state.

Each thread has its own dynamic environment, but a child inherits bindings to the **same parameter cells** as its parent. Assigning an inherited parameter in either thread is visible in the other (`gerbil-dev/src/gambit/doc/gambit.txi:11106-11116`). An installed probe confirmed this.

`parameterize` creates a new local cell for its dynamic extent (`gambit.txi:11273-11307`). Threads created inside that extent inherit that cell. Continuations capture and restore the dynamic environment and `dynamic-wind` stack, even across threads (`gambit.txi:11118-11133`).

Therefore:

- use parameters for dynamically scoped configuration, logging context, current service handles, or trusted execution context;
- do not use them as unsynchronized global state;
- use `make-root-thread` when a new thread must not inherit the parent’s dynamic environment (`gambit.txi:10159-10171`).

Gerbil’s actual thread-local API stores a per-actor-thread hash table, or a mutex-protected weak-key table for plain threads (`gerbil-dev/src/gerbil/runtime/thread.ss:83-129`). It is appropriate for caches and diagnostic context, not authority: it disappears with the thread and is not naturally visible to other threads.

Documentation drift: the reference names `thread-local-clear!` (`gerbil-dev/doc/reference/gerbil/runtime/thread-primitives.md:95-102`), while v19 exports `thread-local-delete!` (`gerbil-dev/src/gerbil/runtime/thread.ss:91-97`). The installed runtime has `delete!`, not `clear!`.

### 11. Exceptions, continuations, and transaction boundaries

A spawned actor thread installs an abortive handler that captures the continuation, runs the debug hook, unwinds the stack, and terminates through the primordial handler (`gerbil-dev/src/gerbil/runtime/thread.ss:60-81`).

`thread-join!`:

- returns the normal result;
- returns/raises a timeout outcome;
- raises the stored termination or uncaught-exception object after abnormal termination.

See `gerbil-dev/src/gambit/doc/gambit.txi:10462-10513`.

For command processing:

- catch ordinary command exceptions inside each loop iteration;
- leave the old immutable root installed until a transition has returned and passed validation;
- complete that command with its original exception;
- continue with later commands;
- distinguish command failure from an invariant failure of the owner loop.

If a command mutates the current graph in place, exceptions do not roll those mutations back.

Continuations need explicit restrictions:

- `let/cc` and `let/esc` are effectively full continuations on Gambit (`gerbil-dev/doc/reference/gerbil/prelude/macros.md:325-335`).
- An escaping continuation is not an exception and can bypass `with-lock` cleanup.
- A stored continuation can later re-enter a dynamic context and replay effects.
- `with-unwind-protect` uses a one-shot guard and rejects re-entry (`gerbil-dev/src/gerbil/runtime/control.ss:40-47`).

Authoritative transition APIs should expect ordinary return/raise behavior and avoid accepting or retaining arbitrary continuations across a commit boundary. Use `with-dynamic-lock` where continuation escape genuinely must be supported.

### 12. Shutdown, failure recovery, and supervision

The primordial thread controls process lifetime: all threads terminate when it exits (`gerbil-dev/src/gambit/doc/gambit.txi:10088-10097`). A long-lived program must keep it alive, usually by joining a lifecycle coordinator or state owner.

Prefer cooperative shutdown:

1. stop accepting new commands;
2. optionally drain already accepted commands;
3. close subscriber/reply channels;
4. request owner termination;
5. join retained thread handles.

`thread-terminate!` is abrupt, cannot perform cleanup, and can leave structures inconsistent (`gambit.txi:10369-10421`). It should be a last-resort containment mechanism.

There is no supported in-process restart supervisor in installed v19. A small application supervisor can join the owner and apply a restart/terminate policy, but recovery has hard questions:

- where the last valid root is stored safely;
- how accepted but unresolved commands are failed or replayed;
- whether effects are idempotent;
- whether a restarted owner reuses or replaces the inbox.

A fatal owner failure should not silently restart unless those semantics are defined.

## Actor and server abstraction availability

| Facility | Installed v19 status | Suitability |
|---|---|---|
| `spawn`, `spawn/name`, raw mailboxes | Available and documented | Good primitive for a custom serial owner. |
| `:std/sync/channel`, completion, atom, RWLock | Available | Current building blocks; documentation module names lag source. |
| Documented `:std/actor` | **Unavailable** | v0.18 API offered selective receive, request/reply timeouts, shutdown, tickers, and monitors (`gerbil-dev/doc/reference/std/actor.md:15-108,282-442`), but cannot be used under the installed constraint. |
| `:std/actor-v13`, actor-v18 supervisor | **Unavailable/inactive** | Sources are under `src/v0.19-WIP`; not an acceptable production dependency. |
| `:std/ensemble/actor` | Available, evolving | Distributed, signed, marshalled actor messaging—not a lightweight state owner. |
| `:std/ensemble` facade | **Unavailable** | Import fails. |
| `gerbil ensemble` supervisor tool | **Broken/unavailable** | Installed invocation fails importing `:gerbil/tools/gxensemble`; current tool source still imports removed `:std/actor` and `:std/actor-v18/registry` (`gerbil-dev/src/tools/gxensemble/srv.ss:1-9`). |
| `:std/event` / documented `select` | **Unavailable** | Retained only in v19 WIP/TODIE source. |
| Generic in-process `gen_server`/supervisor | Not found | Compose owner thread, channel, completion, join, and explicit lifecycle. |

The current ensemble actor interface provides one-way send, blocking invoke, replies, broadcast, expiring and one-shot handlers (`gerbil-dev/src/std/ensemble/interface/actor.ss:68-173`). Each message is marshalled, capability-authorized, and signed (`gerbil-dev/src/std/ensemble/actor/actor.ss:100-167`). Request/reply creates a completion and a timeout thread (`actor.ss:450-481`).

Most importantly, host dispatch spawns a fresh actor thread per message and drops messages when its thread limit is exceeded (`gerbil-dev/src/std/ensemble/host/actor-dispatch.ss:12-46`). Handlers for one actor can therefore overlap. A second serialization layer would still be required for authoritative mutable state.

The advanced-ensemble documentation describes process supervisors that restart workers (`gerbil-dev/doc/tutorials/advanced-ensemble.md:47-65,114-169`), but those facilities depend on removed actor-v18 modules and are not operational in this installed v19.

## Generic state architecture evaluation

### Architecture A: bounded single owner with immutable revisioned root

**Shape**

- One `spawn/name` owner.
- One positive-capacity channel for commands.
- Per-command completion or one-slot reply channel.
- Root contains both exact-integer revision and state.
- Only the owner installs roots.
- Readers either request a snapshot from the owner or read through a separately synchronized publication seam.

**Strengths**

- Total mutation order and coherent revisions.
- Explicit bounded admission and shutdown.
- Failed pure transitions leave the old root untouched.
- Extensions cannot accidentally mutate concurrently if the command boundary is enforced.
- Works equally for interactive, batch, daemon, embedded, or transport-hosted programs.

**Costs/risks**

- All transitions share one throughput and head-of-line blocking point.
- Blocking I/O inside a command stalls the state machine.
- Immutable use is contractual.
- Snapshot publication outside the owner still needs synchronization; raw Atom dereference is not proven SMP-safe.

**Best fit:** complex extensible programs needing lifecycle, overload policy, deterministic commit order, and failure containment.

### Architecture B: one Atom containing immutable `(revision, state)`

**Shape**

- Every operation uses one `atom-swap!`/`atom-swap-values!`.
- The update function constructs a complete replacement root.
- Watchers only enqueue/coalesce notifications and never block.

**Strengths**

- Small API and synchronous caller semantics.
- Root/revision update is one lock-protected mutation.
- Effective for short, independent, pure transitions.

**Costs/risks**

- Transformation, validation, and watches all run under one mutex.
- No command queue, bounded admission, lifecycle, fairness contract, or caller decoupling.
- Reentrant mutation deadlocks.
- Watch failures occur after commit.
- Direct `atom-deref` is unsynchronized in source.
- Future implementation may retry transformations.

**Best fit:** modest state with very short transitions and no need for queued command management.

### Architecture C: mutex/RWLock-protected mutable store

**Shape**

- State is a mutable struct/class/hash graph.
- Every access follows a mutex or RWLock discipline.
- Snapshots are copied while holding the appropriate lock.

**Strengths**

- Lowest allocation for intensive in-place mutation.
- Straightforward interoperability with mutable libraries.
- RWLock may help a future SMP, demonstrably read-heavy workload.

**Costs/risks**

- Mutation authority is distributed among callers and extensions.
- Exceptions after partial mutation do not roll back.
- Lock leaks/deadlocks are possible through callbacks, re-entry, or escaping continuations.
- Copying under lock extends pauses; copying after unlock races.
- RWLock ownership is weakly enforced and its test is disabled by default.
- On the installed non-SMP runtime, RWLock usually adds complexity without multicore read parallelism.

**Best fit:** tightly controlled internal subsystems with short, auditable critical sections and mutable performance requirements.

### Architecture D: raw mailbox or distributed ensemble actor

A raw-mailbox owner is a lower-overhead variant of Architecture A but lacks bounded memory and close semantics. It is acceptable only with a bounded outer admission layer.

The current ensemble actor is materially different: it is a secure distributed message bus with marshalling, signatures, expiring handlers, timeout threads, and concurrent dispatch. It is not a serial in-process state server and is unstable relative to current documentation and tooling.

## Performance summary

No repository benchmark establishes numeric throughput for these alternatives. Source-supported cost ordering is:

- immutable root handoff: O(1) read/handoff, update cost depends on reconstructed paths;
- owner/channel: one queue mutex operation per admission/read plus serialized transition execution;
- Atom: one mutex critical section spanning transformation, validation, assignment, and watches;
- simple mutex: minimal synchronization overhead but highest discipline risk;
- RWLock: extra counters/condition logic, useful mainly for real concurrent read sections;
- shallow copy: O(container size), retains nested aliases;
- serialization deep copy: O(reachable graph size) plus byte buffer and reconstructed graph allocation;
- ensemble actor: marshalling, authorization, signing, dispatch threads, completions, and timer threads.

On the current SMP-disabled runtime, extra compute threads improve responsiveness only when work yields or blocks; they do not increase aggregate Scheme CPU throughput.

## Review findings and residual risks

- **High — persistent collections unavailable:** v19 has no installed standard HAMT/persistent-map implementation. An immutable architecture must use application conventions, copying, small functional structures, or an external dependency.
- **High — documented actor supervision unavailable:** the v0.18 actor and ensemble supervisor documentation cannot be treated as installed v19 API.
- **High — mutable-state exception semantics:** in-place transitions can partially commit before raising; no primitive provides automatic rollback.
- **Medium — Atom dereference memory visibility:** mutations lock, but `atom-deref` is a raw field read. Future SMP use requires confirmation or a synchronized publication seam.
- **Medium — channel close visibility:** close-state accesses are not uniformly under the mutex.
- **Medium — continuation escape:** `with-lock` and RWLock convenience wrappers are not safe against arbitrary escaping continuations.
- **Medium — subscriber/watcher behavior:** Atom watches execute under the commit lock; channel subscribers require an explicit loss, coalescing, blocking, or disconnect policy.
- **Medium — owner failure recovery:** no active in-process supervisor provides safe replay or pending-command resolution.
- **Medium — v19 API drift:** active modules are under `:std/sync/*`, while documentation and test suite names still say `:std/misc/*`; thread-local documentation also names the wrong deletion API.
- **Low/medium — RWLock assurance:** its tests are disabled by default as flaky.
- **Low — current non-SMP limitation:** performance conclusions must be revisited if Gerbil is rebuilt with SMP.

## Confidence

- **High:** installed module availability, channel/completion/Atom/RWLock source semantics, thread lifecycle, parameter inheritance, and SMP status.
- **High:** absence of installed actor-v18 supervision and persistent SRFI 146.
- **Medium-high:** architecture tradeoffs derived directly from synchronization and representation semantics.
- **Medium:** future SMP behavior of current Atom/channel implementations.
- **Low-medium:** stability of the new ensemble actor APIs, which lack matching current documentation and coexist with broken legacy tooling.

## Validation

### Performed

```sh
gerbil test -g \
  gerbil-dev/src/std/sync/atom-test.ss \
  gerbil-dev/src/std/sync/channel-test.ss \
  gerbil-dev/src/std/sync/completion-test.ss
```

All three modules and the test harness passed.

Installed API probes confirmed:

- current `:std/sync/{atom,rwlock,channel,completion}` imports succeed;
- stale `:std/misc/{atom,channel,completion}`, `:std/actor`, `:std/event`, `:std/misc/threads`, `:std/os/signal-handler`, persistent-map candidates, and `:std/ensemble` fail;
- `:std/ensemble/actor` and its actor interface import;
- channel bound/close/drain behavior;
- completion error propagation;
- 100 concurrent Atom increments;
- `AtomicCounter` old-value return;
- shared inherited parameter cells;
- deep serialization copy versus shallow struct/hash copies;
- `gerbil-runtime-smp?` returns `#f`.

### Evidence-backed focused validation after implementation

```sh
cd /home/jay/Code/workbench-gerbil
gerbil test -g \
  gerbil-dev/src/std/sync/atom-test.ss \
  gerbil-dev/src/std/sync/channel-test.ss \
  gerbil-dev/src/std/sync/completion-test.ss
```

Add application-facing concurrency tests for:

- no overlapping transition execution;
- coherent `(revision, state)` snapshots;
- admission timeout/full handling;
- command exception containment;
- continuation policy;
- shutdown drain/reject behavior;
- pending-command behavior after fatal owner failure;
- snapshot alias isolation.

### Full upstream validation

Gerbil documents recursive testing with `gerbil test ./...` at `gerbil-dev/doc/reference/dev/test.md:17-25`. Core contribution guidance specifies:

```sh
cd /home/jay/Code/workbench-gerbil/gerbil-dev
make check
# documented alternative
./build.sh env gerbil test ./...
```

These commands are supported by `gerbil-dev/CONTRIBUTING.md:182-190`. They were not run because this research was bounded to installed API semantics and focused tests.