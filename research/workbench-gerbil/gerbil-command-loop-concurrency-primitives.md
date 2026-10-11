# Gerbil v0.19 command-loop concurrency primitives

## Executive answer

The smallest robust foundation is:

> **One named Gerbil thread that exclusively owns Tuna’s authoritative state, fed by a bounded `:std/sync/channel` command inbox.**

Use:

- `spawn/name` for the owner loop;
- a bounded `make-channel` for command admission and backpressure;
- a per-command `:std/sync/completion` for one-shot success/error when no caller timeout is required, or a one-slot reply channel when timeout is required;
- separate threads for unrelated I/O or computation, with all state commits sent back to the owner loop;
- one bounded channel per event subscriber, with an explicit block/drop/coalesce/disconnect policy;
- cooperative cancel and shutdown commands, followed by `thread-join!`;
- the primordial thread joining the owner or a lifecycle coordinator so the process remains alive.

This gives serialization by ownership rather than locks. It also coexists naturally with the v0.19 HTTP server, whose `start!` returns after spawning listener threads.

Do **not** base the current v0.19 implementation on the documented `:std/actor`, `:std/event`, `:std/misc/threads`, or `:std/os/signal-handler` APIs: those documented v0.18 modules are absent from the installed v0.19 tree.

## Recommended runtime shape

1. **Command owner**
   - A single `spawn/name` loop performs every authoritative state mutation.
   - Its bounded inbox limits memory growth and supplies timeout-capable admission.
   - Subscribe, unsubscribe, snapshot, commit, cancel, and shutdown should all be commands if they must be atomic relative to mutation.

2. **Concurrent work**
   - I/O and pure computation may run in other Gerbil threads.
   - Workers receive immutable inputs or snapshots and return results to the owner.
   - Workers must never mutate authoritative state directly.
   - On this installation, this provides logical concurrency and I/O overlap, but not multicore CPU parallelism.

3. **Completion and errors**
   - A `Completion` carries one successful result or one exception to all waiters; duplicate posting raises an error.
   - `completion-wait!` has no timeout. Use a one-slot reply channel if callers need timeout or abandonment.
   - Catch errors at each command boundary and complete that command with an error without killing the owner. Let genuinely fatal loop errors escape so `thread-join!` reports them.

4. **Events**
   - Maintain one bounded channel per subscriber.
   - For lossless completion events, do not use `channel-try-put` unless dropping is explicitly acceptable.
   - For state-change wakeups where consumers always fetch the latest snapshot, capacity-one plus `channel-try-put` provides coalescing. The Datastar example uses exactly this pattern at `datastar-gerbil/example.ss:19-34,88-99`.

5. **Shutdown and cancellation**
   - Prefer cooperative cancel/shutdown messages and join owned threads.
   - Close command/subscriber channels to wake blocked consumers; queued channel values drain before `#!eof`.
   - Avoid `thread-terminate!` during normal operation: Gambit warns that forced termination is abrupt, cannot clean up, and can leave critical sections inconsistent (`gerbil/src/gambit/doc/gambit.txi:10369-10421`).
   - Keep the primordial thread alive by joining the owner/coordinator. All threads are terminated when the primordial thread exits (`gerbil/src/gambit/doc/gambit.txi:10088-10097`).

## Facilities and status

| Facility | Current semantics and fit | v0.19 status |
|---|---|---|
| Threads and raw mailboxes | `spawn/name` creates an immediately running thread; spawned threads unwind finalizers on unhandled exceptions (`gerbil/src/gerbil/runtime/thread.ss:27-81`). Each thread mailbox is FIFO; `thread-receive` supports timeout/default (`gerbil/src/gambit/doc/gambit.txi:10518-10564`). Excellent owner-loop model, but mailboxes have no documented bound or producer backpressure. | Stable public core/Gambit API; installed. |
| Buffered channels | Mutex-protected queue with optional bound; blocking/timed and nonblocking puts; timed gets; close wakes waiters and drains queued values (`gerbil/src/std/sync/channel.ss:9-127`). Best command ingress when robustness includes bounded memory. | Public and installed as `:std/sync/channel`; documentation still names stale `:std/misc/channel` (`gerbil/doc/reference/std/misc/channel.md:1-20,76-122,202-215,301-326`). |
| Completions | One-shot success/error, wakes all waiters; duplicate completion is an error (`gerbil/src/std/sync/completion.ss:5-72`; documentation at `gerbil/doc/reference/std/misc/completion.md:8-20,92-137,172-207`). | Public and installed as `:std/sync/completion`; documentation uses stale `:std/misc/completion`. No wait timeout. |
| Mutexes and conditions | Core mutual exclusion and condition waiting. Mutexes are non-recursive and self-relocking can deadlock (`gerbil/src/gambit/doc/gambit.txi:9911-9949`). Condition waits may wake spuriously and must recheck in a loop (`gerbil/src/gambit/doc/gambit.txi:10875-10925`). | Stable public core API. Useful inside channels or for a mutex-store alternative, but unnecessary around owner-only state. |
| Legacy actors | Documented selective receive, request/reply timeout, structured errors, graceful shutdown, ticker and monitors (`gerbil/doc/reference/std/actor.md:15-108,282-319,322-442`). Its wallet example demonstrates one actor serializing mutation (`gerbil/doc/guide/intro.md:1790-1823`). | **Unavailable in the installed v0.19 tree.** `:std/actor` import fails. Suitable only if explicitly pinning v0.18. |
| New ensemble actors | Public current interfaces offer send/invoke/reply/broadcast and time-to-live (`gerbil/src/std/ensemble/interface/actor.ss:68-173`). Messages are marshalled, capability-authorized and signed (`gerbil/src/std/ensemble/actor/actor.ss:100-167`). Each received message is dispatched in a newly spawned thread, so it does not inherently serialize mutable actor state (`gerbil/src/std/ensemble/host/actor-dispatch.ss:12-46`). | Installed but not covered by current repository documentation. Heavy and semantically wrong as the smallest state-owner primitive without another serialization layer. |
| Event/select API | Documentation describes waiting on threads, mutex/condition pairs, I/O condition variables and timeouts; `select` uses one helper thread per selector (`gerbil/doc/guide/intro.md:1633-1682`). Its retained source confirms helper creation and forced termination (`gerbil/src/v0.19-WIP/v0.19-TODIE-std/event.ss:67-107`). | **Unavailable in installed v0.19.** Source is under `v0.19-WIP/v0.19-TODIE`; do not depend on it. |
| Timeouts/scheduler | Threads block on I/O, sleep, mutexes and mailboxes; the scheduler uses priorities and quantums (`gerbil/src/gambit/doc/gambit.txi:9874-9909,9955-10043`). Current timeout conversion accepts relative numbers and absolute time representations (`gerbil/src/std/time/timeout.ss:8-63`). No active general timer wheel/scheduler module was found. | Core thread timeouts and `:std/time/*` are public/current. |
| Thread groups | `spawn/group` constructs a new group (`gerbil/src/gerbil/runtime/thread.ss:37-54`). Gambit lists group creation/enumeration/termination under explicitly “Undocumented extensions” (`gerbil/src/gambit/doc/gambit.txi:5366-5384`). The documented Gerbil group-kill helper is in inactive v0.19 WIP source and internally depends on `##`/macro operations (`gerbil/src/v0.19-WIP/v0.19-TODO-std/misc/threads.ss:36-118`). | Group association is available, but bulk-kill/suspend/resume is not a sound stable lifecycle foundation for Tuna. |
| Supervision | Thread joining reports normal result, timeout, termination or uncaught exception (`gerbil/src/gambit/doc/gambit.txi:10462-10513`). There is no documented active in-process restart supervisor. Structured ensembles supervise separate processes and can restart workers (`gerbil/doc/tutorials/advanced-ensemble.md:47-65,114-123,155-169`). | Join/monitor manually in process. Ensemble supervision is materially larger, process-oriented infrastructure. |
| Signals | Stale docs name signal constants and add/remove handlers but largely say “Please document me” (`gerbil/doc/reference/std/os/signal.md:1-79`; `signal-handler.md:1-18`). The old Linux implementation used `signalfd` and a dispatch thread (`gerbil/src/v0.19-WIP/v0.19-TODO-std/os/signal-handler.ss:21-95`). | **High-severity gap:** installed v0.19 cannot import `:std/os/signal-handler`. Gambit’s `current-user-interrupt-handler` is itself listed without documentation (`gerbil/src/gambit/doc/gambit.txi:5505-5508`) and is not a verified SIGTERM solution. |
| HTTP lifecycle | Public `Server` supports `start!`, `stop!`, `restart!`, active connections and config (`gerbil/src/std/net/http/server/interface.ss:82-133`). Start creates listener threads; each connection gets a handler thread (`gerbil/src/std/net/http/server/server.ss:39-112,150-166`). | Public and installed as `:std/net/http/server`. Compatible with a separate state owner. |

## HTTP coexistence and lifecycle

The Datastar example establishes the intended lifecycle without requiring any route design:

- construct `ServerConfig` and `new-http-server`;
- call `server.start!`;
- keep the primordial thread alive;
- call `server.stop!` in `finally` (`datastar-gerbil/example.ss:104-121`).

`start!` is nonblocking after listener creation (`gerbil/src/std/net/http/server/server.ss:50-112`). The server has its own thread group, listener table and active-handler table (`server.ss:27-48`). `stop!` closes listener and client sockets, waits up to roughly three seconds for tracked threads, then forcibly terminates remaining threads (`server.ss:114-138`). HTTP handlers already run concurrently (`server.ss:150-166`), so they can submit to the bounded Tuna command channel and wait for their individual replies.

The runtime owner should remain independent of the HTTP server’s internal thread group. Shutdown coordination should explicitly stop admission, stop the HTTP server, request owner shutdown, and join the owner rather than relying on HTTP internals.

## SMP and performance implications

The installed runtime reports:

- Gerbil `v0.19-dev-31-g4a4d1a30`;
- `gerbil-runtime-smp?` → `#f`;
- configure command contains no `--enable-smp`.

Runtime detection checks the configure string for `--enable-smp` (`gerbil/src/gerbil/runtime/system.ss:61-67`), while the public documentation defines `gerbil-runtime-smp?` at `gerbil/doc/reference/gerbil/runtime/system-information.md:18-23`.

Consequences:

- I/O, timers and command submissions remain concurrently schedulable as Gerbil threads.
- CPU work is not parallel across cores; all Scheme work shares one runtime virtual processor.
- Moving CPU work to extra Gerbil threads can improve responsiveness but not aggregate CPU throughput.
- The old Gambit manual’s statement that at most one thread runs (`gambit.txi:9826-9830`) matches this installation but is not universally true for SMP-enabled builds. Gerbil’s thread utility documentation explicitly conditions multicore operation on an SMP-enabled Gambit (`gerbil/doc/reference/std/misc/threads.md:271-293`).

Source-level cost considerations, without unsupported benchmark numbers:

- raw mailboxes avoid the channel queue/mutex layer but are unbounded;
- every channel put/get takes its mutex and may broadcast a condition (`gerbil/src/std/sync/channel.ss:30-63,77-115`);
- legacy `select` allocates one thread per selector, making it inappropriate as a high-frequency central command loop;
- current ensemble actors add marshalling, authorization, signatures, temporary completions and timeout threads (`gerbil/src/std/ensemble/actor/actor.ss:100-167,450-494`);
- the single owner is intentionally the mutation throughput bottleneck, while unrelated operations remain concurrent;
- no concurrency benchmark in this checkout justifies a numeric throughput or latency claim.

## Material alternatives

### 1. Raw mailbox owner

Use `thread-send`/`thread-receive` directly.

**Advantages:** smallest dependency surface; FIFO delivery; receive timeout; clean actor-style ownership.

**Disadvantages:** no backpressure or close operation; a stalled owner permits unbounded queued commands. Appropriate only with externally bounded admission.

### 2. Bounded channel owner — recommended

Use a bounded channel as the inbox and a named thread as its sole consumer.

**Advantages:** explicit memory bound, submission timeout, nonblocking admission option, close/EOF shutdown, straightforward tests.

**Disadvantages:** v0.19 documentation has not caught up with the module rename; each operation adds queue/mutex synchronization.

### 3. Mutex-protected global store

Allow request threads to mutate one shared state under `with-lock`.

**Advantages:** least code for very short synchronous mutations.

**Disadvantages:** mutation ownership is distributed; accidental I/O or callbacks inside the lock block all state access; event publication and atomic subscription are easier to get wrong. `with-lock` itself safely unlocks during exception propagation (`gerbil/src/gerbil/runtime/thread.ss:138-158`), but it cannot define higher-level lock scope policy.

### 4. Actor packages

- Pinning v0.18 makes the documented legacy actor loop a strong semantic match.
- The current v0.19 ensemble actor is not a replacement for serial ownership because handler messages are dispatched concurrently, and its distributed security/marshalling machinery is unnecessary for an in-process command loop.

## Risks and unresolved gaps

- **High — process signals:** no verified public v0.19 SIGINT/SIGTERM handler module is installed. Explicit application shutdown is available, but service-manager signal behavior remains unresolved.
- **High — cancellation semantics:** forced termination is unsafe. Cooperative cancellation requires commands to reach cancellation points; a long non-yielding foreign call cannot be made safely cancellable by these primitives alone.
- **Medium — documentation/API drift:** current source is `v0.19-dev-32`, installed tools are `v0.19-dev-31`, while concurrency documentation primarily describes v0.18 module names.
- **Medium — future SMP audit:** `channel-close` checks `eof` before taking the mutex and `channel-closed?` reads it without locking (`gerbil/src/std/sync/channel.ss:117-127`). Gambit states that concurrent store reads/writes require synchronization (`gambit.txi:10045-10053`). This is not a demonstrated failure on the current SMP-disabled runtime, but deserves upstream confirmation or stress testing before enabling SMP.
- **Medium — slow subscribers:** bounded delivery requires a deliberate loss/backpressure policy. Blocking publication can stall the owner; `try-put` can lose events.
- **Medium — fatal owner failure:** there is no active documented in-process restart supervisor. Retain and join the owner handle; decide externally whether a fatal failure terminates or restarts the process.
- **Low — thread groups:** useful for inspection and containment, but active stable bulk lifecycle APIs are insufficiently documented.
- The nested `gerbil` checkout was already dirty in generated Gambit C files; no conclusions depend on those generated diffs.

## Confidence

- **High:** active thread, mailbox, channel, completion and HTTP source semantics.
- **High:** installed module availability and SMP-disabled result.
- **High:** legacy actor/event/signal/thread-helper modules are absent from the installed v0.19 library.
- **Medium:** long-term stability of evolving v0.19 `:std/sync/*`, `:std/ensemble/*`, and HTTP APIs.
- **Low/medium:** behavior after a future SMP rebuild until concurrency stress tests and signal integration are performed.

## Validation

Focused validation performed:

```sh
gerbil test -g \
  gerbil/src/std/sync/channel-test.ss \
  gerbil/src/std/sync/completion-test.ss
```

Both modules and the harness passed.

Installed API/SMP smoke test performed:

```sh
gxi -e '(begin
  (import :std/sync/channel :std/sync/completion)
  (let ((ch (make-channel 1)) (c (make-completion)))
    (channel-put ch 42)
    (completion-post! c (channel-get ch))
    (displayln (completion-wait! c))
    (channel-close ch))
  (displayln (gerbil-runtime-smp?)))'
```

Output was `42` and `#f`.

Recommended focused validation after implementation:

```sh
cd /home/jay/Code/workbench-gerbil/gerbil
./build.sh env gerbil test \
  src/std/sync/channel-test.ss \
  src/std/sync/completion-test.ss
./build.sh env gerbil test src/std/net/http/http-test.ss
```

Recommended full upstream validation:

```sh
cd /home/jay/Code/workbench-gerbil/gerbil
make check
# documented alternative:
./build.sh env gerbil test ./...
```

The full commands are supported by `gerbil/CONTRIBUTING.md:187-190` and `gerbil/doc/reference/dev/test.md:6-24`.