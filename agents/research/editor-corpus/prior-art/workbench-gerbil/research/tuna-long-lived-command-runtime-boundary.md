# Tuna long-lived command runtime boundary

## Conclusion

The next justified substrate is a **host-neutral, instance-owned command runtime**: one worker owns an opaque immutable state snapshot, accepts named commands through a bounded channel, resolves Tuna actions at execution time, installs one validated state transition at a time, completes each command, and publishes coalesced state-change notifications.

This provides the serialization and latest-state read seam needed by a future Command Query Responsibility Segregation (CQRS) read side without adding HTTP, routes, rendering, Datastar, browser sessions, keymaps, or input decoding.

## Why this boundary fits

Tuna already provides the correct live command resolution primitive:

- Actions atomically group implementation, descriptor, and argument acquirer: `tuna/lib/bindings.ss:31-40,202-217`.
- `invoke-action-with-context` snapshots one current action generation, derives arguments from an opaque context, validates them, then invokes it: `tuna/lib/bindings.ss:236-258`.
- The roadmap explicitly keeps host context opaque and excludes keymaps, rendering, input, and event loops: `plans/emacsen-runtime/checklist.md:207-223`.
- Current live cells only guarantee individual atomic replacement, not multi-cell or application-state transactions: `plans/emacsen-runtime/checklist.md:175-185`; `tuna/README.md:208-214`.

What Tuna lacks is a long-lived owner of application state and work. Its current `main` loads configuration, invokes demonstrations directly, and exits after shutting down logging; it has no command queue, state owner, completion protocol, or runtime worker: `tuna/main.ss:8-66`.

The Datastar example demonstrates the useful downstream pattern without defining the runtime boundary: concurrent ticker/request producers mutate mutex-protected globals, while capacity-one subscriber channels carry nonblocking wakeups and consumers reread current state: `datastar-gerbil/example.ss:8-45,81-102`. HTTP, rendering, and server lifecycle begin only afterward at `datastar-gerbil/example.ss:47-121`; they should remain a future adapter.

## Options

| Option | Shape | Tradeoff |
|---|---|---|
| **A. Opaque-state transition runtime — recommended** | One bounded intake channel and one named worker. A queued action returns a validated transition containing `next-state`, command result, and `changed?`. The worker atomically installs `(revision, state)`, completes the request, then sends nonblocking wakeups. | Strongest CQRS seam and clean error behavior. Requires a small queued-command result contract layered over existing actions; immutable state is contractual rather than enforceable by Gerbil. |
| **B. Imperative action executor** | Same worker and queue, but actions mutate actor-confined state directly and return an ordinary result/change token. | Smaller adaptation of M6, but an action can mutate and then fail; serialization is guaranteed, rollback and reliable change classification are not. |
| **C. Mutex-wrapped direct dispatch** | Producers invoke M6 under one mutex. | Least code, but lacks bounded intake, admission policy, asynchronous completion, owned lifecycle, fairness, and separation from blocking producer I/O. It is not a sufficient long-lived substrate. |

Existing research independently favors one state actor plus bounded subscriber/command channels over a mutex store or ensemble bus: `research/northstar-gerbil-runtime-options.md:70-93,107-139,214-235,475-497`.

## Recommended minimal milestone

### Command runtime contract

1. **Instance and state**
   - Construct a runtime with an initial opaque immutable state and positive intake capacity.
   - Keep `(revision, state)` in one atom readable as a coherent snapshot.
   - Do not introduce a process-global application singleton.

2. **Command intake and resolution**
   - A request contains an interned action symbol, either explicit arguments or an opaque context snapshot, and a capacity-one completion channel.
   - The worker resolves the action **when dequeued**, not when submitted, preserving M6 name-backed replacement semantics.
   - Context acquisition receives the submitted opaque context plus the current authoritative state; it must not depend on HTTP/request/session types or provisional M5 contexts. M5 remains explicitly host-undecided: `plans/emacsen-runtime/checklist.md:189-205`.

3. **Authoritative mutation**
   - Exactly one worker invokes transitions.
   - On a normal, validated transition, atomically replace `(revision, state)` and increment the revision.
   - Invalid transitions or action exceptions leave the runtime-owned state pointer unchanged. Arbitrary external side effects remain nontransactional, consistent with existing exclusions: `plans/emacsen-runtime/checklist.md:31-38,225-229`.

4. **Concurrent producers and I/O**
   - Any number of producer threads may parse input or perform independent I/O concurrently, then submit immutable command data.
   - Only the runtime worker may install authoritative state.
   - Slow/blocking I/O inside an action stalls all commands; a worker pool, effect scheduler, retries, and cancellation are therefore deferred.

5. **Completion and errors**
   - Provide nonblocking `try-submit` returning accepted/full/not-running and an optional timed submission based on `channel-put`.
   - Every accepted request completes exactly once with typed success or failure.
   - Catch action/acquirer/transition errors per command, preserve the original condition, and continue processing later commands.
   - An internal runtime invariant failure moves the runtime to `failed`, rejects new work, and completes queued work as runtime-failed.

6. **State-change publication**
   - Publish only a revisioned **latest-state invalidation**, not arbitrary hooks or a durable domain-event log.
   - Each subscriber has a bounded capacity-one channel. `channel-try-put` coalesces wakeups; consumers reread the coherent latest snapshot.
   - Command completion occurs after state installation and nonblocking notification attempts, not after consumers observe or render it.
   - Gerbil channels support bounded/timed puts, immediate try-put, FIFO reads, and close/drain/EOF behavior: `gerbil/src/std/sync/channel.ss:15-63,77-127`.

7. **Lifecycle**
   - Explicit states: created → running → stopping → stopped, plus failed.
   - Start one retained named worker; reject double start.
   - Shutdown rejects new submissions, drains already accepted commands, closes subscriptions, and joins the worker.
   - Load startup configuration before starting the runtime. Existing selection and diagnostics remain unchanged: `tuna/lib/startup.ss:6-31`; `tuna/lib/config.ss:7-41`.
   - Stop the runtime before stopping/joining logging, whose current shutdown is explicit: `tuna/lib/log.ss:23-30`.
   - Runtime config reload while commands are active and operating-system signal integration remain separate work.

## How M8 should change

Current M8 proposes synchronous deterministic named/captured listeners: `plans/emacsen-runtime/checklist.md:260-270`, with dependency entry at `plans/emacsen-runtime/checklist.md:359-375`.

Reshape the ordering:

1. **M8A — serialized command runtime:** bounded intake, dequeue-time M6 resolution, one state owner, completion, error containment, lifecycle.
2. **M8B — latest-state publication:** coherent snapshot plus bounded/coalesced invalidation subscribers.
3. **Hooks/events — defer or renumber:** retain only when a concrete package-cooperation use case requires callbacks.

Generic sequential hooks are the wrong CQRS publication seam: a slow or failing callback would run on and stall the authoritative mutation path. A channel-based latest-state feed makes backpressure explicit and matches the fat-morph need to rerender current state rather than replay every intermediate notification. Existing research warns that unbounded buses leak memory and recommends project-owned bounded channels: `research/northstar-gerbil-runtime-options.md:263-291`.

## Acceptance boundaries and test seams

Use an independent fixture, not Tuna application/demo files, as required by `plans/emacsen-runtime/checklist.md:62-68,377-389`.

Minimum observable acceptance:

- replacement while a command is queued causes dequeue-time name resolution to invoke the new action;
- concurrent producers preserve each producer’s order, generate one total processing sequence, and never overlap handlers;
- full intake returns a controlled admission result without dropping an accepted command;
- success installs one coherent state/revision, completes once, and wakes subscribers;
- an action exception or invalid transition completes as failure, leaves state unchanged, and does not kill the worker;
- a full subscriber channel never blocks command processing and later snapshot reads see the newest revision;
- shutdown drains accepted commands, closes subscribers, joins the worker, and rejects later submissions;
- source execution, normal `gxc`, and `gxc -O` pass; full-program optimization remains characterization-only.

Do not add HTTP fixtures, route handlers, HTML, Server-Sent Events (SSE), Datastar patches, browser tests, session/request contexts, persistence, or keymaps to this milestone.

## Premature work

- HTTP/server lifecycle, routes, request parsing, browser/session identity, Datastar events, HTML/fat-morph rendering.
- Deepening M5 into request/session-local state.
- SQLite, event sourcing, durable command logs, replay, distributed brokers, ensemble actors, TTL, or cross-process delivery.
- Command priorities, cancellation, deduplication, retries, undo/history, deadlines, or worker pools.
- Generic synchronous hooks, advice, or arbitrary listener mutation during authoritative processing.
- Concurrent live config reload, transactional config loads, unload, and native module reload.
- Assuming every state notification is lossless; that requires a different event-log contract than latest-state invalidation.

## Risks and unresolved owner decisions

- **High — toolchain preflight currently fails:** the plan requires nested Gerbil commit `4a4d1a30…`, but the checkout is `4531c21b…`; the installed tool is still dev31 at `4a4d1a30`. No new fixture evidence is valid until the approved pin is aligned or revised. Requirement: `plans/emacsen-runtime/checklist.md:377-438`.
- **Medium — transition versus imperative state:** Option A prevents failed commands from installing a new authoritative snapshot; Option B is smaller but permits partial in-place mutation.
- **Medium — publication semantics:** latest-state invalidation may coalesce; a requirement to preserve every domain event needs a separate bounded/disconnect or durable-log decision.
- **Medium — overload default:** choose whether ordinary submission blocks with a timeout or rejects immediately when full; accepted commands must never be silently discarded.
- **Medium — symmetric multiprocessing:** true multicore contention remains unmeasured: `plans/emacsen-runtime/checklist.md:600-610`.
- **Low — shutdown policy:** recommended behavior drains accepted commands; owner may instead require bounded shutdown and cancellation.
- **Low — signal handling:** current v0.19 signal integration remains unverified: `research/northstar-gerbil-runtime-options.md:293-310`.

**Confidence:** High that a bounded single-owner state-transition runtime is the smallest defensible host-neutral boundary; medium-high on exact API shape pending the transition/publication decisions.

## Validation commands

No tests were run during this read-only research.

After toolchain alignment, focused channel validation is evidence-backed at `research/northstar-gerbil-runtime-options.md:528-543`:

```sh
cd /home/jay/Code/workbench-gerbil/gerbil
./build.sh env gerbil test src/std/sync/channel-test.ss
```

The command-runtime fixture should use the sanitized `gxi`, normal `gxc`, `gxc -O`, and experimental full-program matrix exactly as specified in `plans/emacsen-runtime/checklist.md:377-596`.

Full upstream validation:

```sh
cd /home/jay/Code/workbench-gerbil/gerbil
make check
# documented alternative
./build.sh env gerbil test ./...
```