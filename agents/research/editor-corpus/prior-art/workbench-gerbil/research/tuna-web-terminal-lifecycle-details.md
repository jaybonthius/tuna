# Tuna web terminal lifecycle/API details

## Conclusion

**Recommended:** use one package-owned completion-observation service with:

- one `spawn/name` worker stored and later joined;
- a bounded channel of `CommandCompletion` values, capacity `C + 1` for Tuna runtime inbox capacity `C`;
- one private ingress/registration mutex covering Tuna submission and blocking completion registration;
- `channel-put`, never `channel-try-put`, before returning an accepted status to the POST handler;
- sequential `command-completion-wait!`, with per-item exception logging and containment;
- `channel-close` plus EOF drain after HTTP handlers are quiescent;
- shutdown order: close ingress and stop Tuna, join Tuna, `server.stop!`, close/join the observer, then `shutdown-logging!`.

This is race-free for ordinary concurrent admission and cooperative shutdown. It preserves admission-only semantics: registration may delay `204`, but completion never does.

**Confidence:** high for the Gerbil/Tuna APIs and lifecycle ordering; medium-high for the package design because the package does not yet exist and Gerbil’s server has a hard three-second handler-termination fallback.

## 1. Completion-observation service

### Required private shape

Conceptually, the package should own:

- channel;
- tracked worker thread;
- ingress/registration mutex;
- accepting/closed state;
- runtime capacity used to derive channel capacity;
- optional stored observer-internal failure for shutdown diagnostics.

Start the worker before starting the HTTP server. `spawn/name` returns a thread (`gerbil/src/gerbil/runtime/thread.ss:27-54`); use ordinary one-argument `thread-join!` for an unbounded guaranteed drain. Gerbil also supports timeout/default forms, but a timeout would weaken the “all accepted failures observed before logger shutdown” guarantee (`gerbil/src/gerbil/builtin.ssxi.ss:1655-1662`).

### Capacity

For runtime inbox capacity `C`, use observer channel capacity `C + 1`:

- Tuna’s bounded inbox holds `C` requests (`tuna/tuna/lib/runtime.ss:69-78`).
- One additional request may already be executing outside that inbox.
- `C + 1` therefore absorbs one completely occupied runtime generation without requiring the observer to be scheduled first.
- Once the observer falls behind completed commands, blocking registration backpressures later HTTP admission rather than accumulating an unbounded waiter/thread list.

Using exactly `C` is materially valid but may block the final acknowledgment in an initial full burst until the observer consumes one item. An unbounded channel or one thread per completion does not satisfy the lifecycle/boundedness requirement.

Do not use `channel-sync`: despite the channel limit, it enqueues all supplied values without checking capacity (`gerbil/src/std/sync/channel.ss:65-75`).

### Submission and registration

The private POST admission operation should serialize this sequence under one ingress/registration mutex:

1. Confirm package ingress is open.
2. Call:
   ```scheme
   (command-runtime-submit-transition!
    runtime 'terminal-dispatch (list raw-request))
   ```
3. On `accepted`, call blocking:
   ```scheme
   (channel-put observer-channel completion)
   ```
4. Release the mutex.
5. Only then permit the handler to issue `204`.

Tuna admission is atomic under its runtime mutex and returns only `accepted`, `full`, or `not-running`; a completion exists only for `accepted` (`tuna/tuna/lib/runtime.ss:279-306`). `channel-put` blocks when full, returns `#t` after enqueue, and raises if the channel is closed (`gerbil/src/std/sync/channel.ss:30-47`).

The private mutex is important:

- it makes registration order match Tuna admission order;
- it permits at most one accepted-but-not-yet-enqueued completion;
- shutdown can close ingress and call `command-runtime-stop!` only after any accepted request has registered;
- a full observer queue backpressures new Tuna submissions instead of allowing many HTTP handlers to accept work and then block independently.

`204` is therefore earned by **accepted plus durably registered**, not by Tuna admission alone. `full`, `not-running`, and closed package ingress map to `503` and enqueue nothing.

### Worker semantics and containment

The sole observer worker should:

1. `channel-get`;
2. exit only when the result is EOF;
3. call `command-completion-wait!` sequentially;
4. ignore successful results;
5. catch each completion exception, issue one structured error log, and continue;
6. contain logging/observer-local failures so one bad record cannot terminate the loop.

Tuna posts successful results or stores per-command exceptions in the completion; command exceptions do not kill its owner (`tuna/tuna/lib/runtime.ss:173-196`). `command-completion-wait!` re-raises the stored exception (`tuna/tuna/lib/runtime.ss:308-310`; underlying behavior at `gerbil/src/std/sync/completion.ss:33-44`). Existing tests demonstrate failure followed by later successful work (`tuna/tuna/test/command-runtime-test.ss:162-170`).

A suitable structured record contains controlled fields such as:

- `transition: 'terminal-dispatch`
- `exception: (exception->string exception)`

`exception->string` is public at `gerbil/src/std/error.ss:419-421`.

The independent package should define its own logger with `deflogger`, because Tuna’s log module exports only `log.info`, not `log.error` (`tuna/tuna/lib/log.ss:14-21`). `deflogger` generates `.error` and related macros (`gerbil/src/std/log/user.ss:11-46`; `gerbil/src/std/log/macros.ss:16-42`). Structured keyword/value arguments become the record data alist (`macros.ss:44-50`).

If logging itself fails, the worker should retain that service failure and continue draining, optionally writing a last-resort diagnostic to the error port. Absolute “every failure logged” cannot be guaranteed after the logging subsystem itself fails; this is a residual infrastructure failure, not a reason to alter an already-issued `204`.

## 2. Drain and shutdown semantics

### Use channel close/EOF, not an ordinary sentinel

Gerbil channel close is drain-preserving:

- `channel-close` marks EOF and wakes waiters (`gerbil/src/std/sync/channel.ss:117-124`);
- queued values remain readable;
- `channel-get` returns EOF only when the queue is empty and closed (`channel.ss:77-96,101-102`).

Therefore shutdown should close the observer channel once producers are quiescent, and the worker should test `eof-object?`. No sentinel is needed.

If an explicit sentinel is selected instead, it must be a private identity value and must be enqueued only after all producers are quiescent. Closing the channel is simpler, does not consume capacity, and has authoritative built-in drain semantics.

Only the lifecycle owner should close the channel; concurrent close calls are unnecessary.

### Exact recommended unwind order

1. Under the private ingress mutex, mark ingress closed and call `command-runtime-stop!`.
2. Release the ingress mutex.
3. `command-runtime-join!`.
4. `server.stop!`.
5. `channel-close` on the observer queue.
6. `thread-join!` the observer worker.
7. Emit any final host lifecycle log.
8. `shutdown-logging!`.

Why:

- Tuna stop changes `running` to `stopping`, closes its inbox, rejects later admission, and drains already accepted work (`tuna/tuna/lib/runtime.ss:350-362`; tested at `test/command-runtime-test.ss:172-193`).
- Runtime finish changes state and closes all remaining subscriptions (`runtime.ss:216-227`).
- `command-runtime-join!` joins only Tuna’s worker; it does not join package observers (`runtime.ss:364-372`).
- Joining Tuna first guarantees every registered command completion is ready and wakes SSE handlers by closing subscription channels.
- Keeping the observer open through `server.stop!` avoids closing it while a handler may still be completing registration.
- Joining the observer before logging shutdown ensures all failure records have been sent before the logger receives its stop message.
- Tuna’s `shutdown-logging!` sends `!STOP!` and joins the logger thread (`tuna/tuna/lib/log.ss:26-30`); the logger processes records and stops sinks on STOP (`gerbil/src/std/log/system.ss:122-148`).

Cleanup must use nested `finally` blocks so a runtime join or server error cannot skip observer and logger cleanup. Retain and re-raise the primary host failure only after cleanup.

### Server “wait” API

There is **no public `server.wait!`**. The `Server` interface exposes `start!`, `stop!`, `active-connections`, `config`, and `restart!` only (`gerbil/src/std/net/http/server/interface.ss:111-133`).

`server.stop!` is synchronous and performs the wait itself:

- closes listener and handler sockets;
- waits for listener/handler tables to empty;
- after three seconds, terminates remaining threads;
- stops the configured server log sink (`gerbil/src/std/net/http/server/server.ss:114-138`).

The three-second forced-termination fallback is a material residual risk. The ingress mutex ensures every accepted command has registered before shutdown begins, so forced termination of a response-writing handler cannot lose its completion observation.

## 3. `/subscribe` during shutdown

Current Tuna behavior is exact:

- `command-runtime-subscribe-state!` accepts both `running` and `stopping`;
- it rejects `created`, `stopped`, and `failed` with an untyped generic error;
- registration and the initial revision/root snapshot are atomic under the runtime mutex (`tuna/tuna/lib/runtime.ss:312-328`).

Recommended route behavior:

- **Running:** subscribe and begin SSE normally.
- **Stopping, if subscription registration succeeds:** begin a short, valid SSE response, send the returned initial snapshot, then observe EOF and return. Runtime shutdown closes the subscription after draining.
- **Stopped/failed before subscription registration:** issue an ordinary `503 Service Unavailable` before calling `call-with-datastar-sse`; never allow the generic inactive-runtime error to become an incidental `500`.
- **Already subscribed but runtime stops before SSE headers begin:** the subscription is valid. Begin SSE, send its atomic initial snapshot, then terminate on EOF; do not attempt to replace it with an ordinary error.

Because Tuna’s inactive error has no public typed predicate, there are two implementation options:

1. **Recommended lifecycle gate:** the package-owned ingress state is closed atomically with host-initiated runtime stop. New `/subscribe` requests then receive `503` without calling Tuna. A request that already obtained a subscription owns it through cleanup.
2. Directly catch subscription failure and inspect `command-runtime-state`; map an inactive terminal state to `503`, otherwise re-raise. This covers unexpected runtime failure but may mask an unrelated error that coincides with terminal state.

Every successfully created subscription must still call `state-subscription-close!` in `finally`. EOF is the normal shutdown result: subscription shutdown behavior is tested at `tuna/tuna/test/state-runtime-test.ss:294-307`.

After SSE headers have been committed, do not attempt an ordinary `500`/`503`; Gerbil response handlers reject a second response action (`gerbil/src/std/net/http/server/request.ss:77-86`), while the outer server exception path otherwise attempts `500` (`server.ss:233-246`).

## 4. Ordinary HTTP response API

Importing `:std/net/http/server` publicly re-exports the interface, statuses, server, mux, and handlers (`gerbil/src/std/net/http/server.ss:1-5`; `server/api.ss:3-19`).

`ResponseHandler-write!` requires:

```scheme
(ResponseHandler-write! response status headers body-u8vector)
```

- `status` must be a `Status`;
- `headers` is a list of string dotted pairs;
- `body` must be a u8vector;
- every handler must invoke exactly one response action (`gerbil/src/std/net/http/server/interface.ss:29-42,63-70`).

Use `string->utf8` for text. Empty `204` is:

```scheme
(ResponseHandler-write! response No-Content '() #u8())
```

This exact seam is used by the Datastar example (`datastar-gerbil/example.ss:81-105`). Gerbil emits no content-length/body fields for a zero-length body (`gerbil/src/std/net/http/server/request.ss:90-142`).

### Statuses

Prefer public named constants:

- `OK`
- `No-Content`
- `Bad-Request`
- `Method-Not-Allowed`
- `Unsupported-Media-Type`
- `Service-Unavailable`

They are exported `Status` instances (`gerbil/src/std/net/http/server/status.ss:15-27,32-72`). The public `Status` constructor takes a fixnum and string, and `status-code->status` exists, but custom construction is unnecessary for these routes.

### Exact recommended headers

| Response | Headers |
|---|---|
| HTML page | `("Content-Type" . "text/html; charset=utf-8")`, optionally `("Cache-Control" . "no-store")` |
| Versioned ESM assets | `("Content-Type" . "text/javascript; charset=utf-8")`, `("Cache-Control" . "public, max-age=31536000, immutable")` |
| Text errors | `("Content-Type" . "text/plain; charset=utf-8")`, preferably `("Cache-Control" . "no-store")` |
| `405` on `/` | above text headers plus `("Allow" . "GET, POST")` |
| `405` on subscribe/assets | above text headers plus `("Allow" . "GET")` |
| Accepted POST `204` | empty header list and `#u8()` |
| Pre-SSE inactive `503` | ordinary text/plain response, not a Datastar response helper |

There is no separate Content-Type, Cache-Control, or Allow API; they are ordinary header alist entries. Gerbil’s own example constructs `Allow` this way (`datastar-gerbil/example.ss:88-99`).

`text/javascript` is the locally evidenced JavaScript MIME type: Datastar’s script response builder emits it and tests it exactly (`datastar-gerbil/http/private/core.ss:372-385`; `core-test.ss:138-153`).

Do not use `response/datastar-elements`, `response/datastar-signals`, or `response/datastar-script` for page/assets/errors/204. Those are one-shot Datastar patch-response helpers (`datastar-gerbil/http/api.ss:89-161`). `call-with-datastar-sse` remains correct only for the established stream after successful subscription (`api.ss:163-168`; SSE headers at `sse-gerbil/sse.ss:19-38`).

## 5. Current environment and constraints

- Checked-out authoritative Gerbil source is `4531c21b`, `v0.19-dev-32`, with unrelated dirty Gambit-generated files.
- Active `/opt/gerbil/bin/gxi` and `gerbil` are still `v0.19-dev-31-g4a4d1a30`.
- The inspected channel, thread, server, and log files are unchanged between dev31 and `4531c21b`.
- The active runtime still lacks the completed chunk terminator fix at `gerbil/src/std/net/http/common/chunked.ss:102-116`; `4531c21b` adds the final newline.
- Therefore lifecycle/API conclusions apply, but completed-SSE acceptance remains blocked until the executing tools are rebuilt from `4531c21b` or a descendant.
- `tuna/packages/tuna-web-terminal` does not yet exist, so no package test command can currently be verified.

## 6. Failure cases and residual risks

- **High:** closing the observer before ingress/server quiescence makes `channel-put` raise and can leave accepted work unobserved.
- **High:** `channel-try-put` would permit silent observation loss when full.
- **High:** an uncaught completion exception would terminate the only observer; catch per item.
- **High:** shutting down logging before observer join can discard required error records.
- **Medium:** bounded registration intentionally delays `204` when observation is backpressured. It still does not wait for command completion.
- **Medium:** Gerbil server stop forcibly terminates remaining handlers after three seconds.
- **Medium:** logger or sink failure prevents an absolute logging guarantee; retain/report observer-internal failures.
- **Medium:** Tuna’s inactive subscription error is untyped; prefer the package lifecycle gate rather than exception-message matching.
- **Medium:** a stopping runtime may produce a very short SSE stream. This is supported and wire-correct; rejecting all shutdown-time streams with `503` is the alternative gate policy.
- **Blocker:** active dev31 cannot validate completed SSE wire framing.

## 7. Validation commands

Run only after `gxi` and `gerbil` report `4531c21b` or a descendant.

Focused Tuna lifecycle foundation:

```sh
cd /home/jay/Code/workbench-gerbil/tuna/tuna
test/run-command-runtime-matrix.sh
```

The matrix runs source, normal compiled, and optimized compiled suites and verifies unchanged worktrees (`tuna/tuna/test/run-command-runtime-matrix.sh:29-105`).

Datastar/SSE foundation:

```sh
cd /home/jay/Code/workbench-gerbil/datastar-gerbil
gerbil build
gerbil test -v 0 ./...
gerbil test -v 0 -D datastar-conformance ./http/conformance-test.ss
```

Documented at `datastar-gerbil/README.md:15-31`.

The eventual package-focused test target should prove:

- queue capacity/backpressure;
- concurrent submit/register ordering;
- `204` only after registration;
- completion failure logging followed by later success;
- stop during accepted-registration;
- EOF drain and worker join;
- logger remains alive until observer completion;
- stopping short-SSE and stopped pre-SSE `503`;
- exact Content-Type, Cache-Control, Allow, empty-204, and body bytes.

No exact package command can be evidence-backed until its package/build/test target exists.