# Northstar Gerbil runtime options

## Executive answer

A single-process Northstar clone does not need NATS as a message broker. Gerbil can cover the runtime responsibilities with:

- the current HTTP server and static multiplexer;
- a project-owned state actor or mutex-protected store;
- one buffered channel per subscriber;
- a TTL sweeper or lazy expiry using thread/mailbox timeouts;
- SQLite when restart persistence is required;
- native chunked HTTP streaming for Server-Sent Events (SSE);
- `:std/log`, `:std/encoding/json`, `:std/crypto/random`, `:std/source`, and `:std/test`.

The most important constraint is version drift. The inspected checkout is Gerbil `4531c21b90fa6ee04f374af905ae3ddb9d89d590` (`v0.19-dev-32`), but much of `gerbil/doc/reference` still describes v0.18 modules that no longer exist at HEAD:

| Documented v0.18 name | Current checkout |
|---|---|
| `:std/net/httpd` | `:std/net/http/server` |
| `:std/misc/channel` | `:std/sync/channel` |
| `:std/logger` | `:std/log` |
| `:std/text/json` | `:std/encoding/json` |
| `:std/config` | absent |
| `:std/actor` | absent; new ensemble work exists |
| `:std/misc/uuid` | absent |

Evidence: current facades are `gerbil/src/std/net/http/server.ss:1-5`, `gerbil/src/std/sync/channel.ss:1-13`, `gerbil/src/std/log.ss:1-5`, and `gerbil/src/std/encoding/json.ss:1-18`. Git tree inspection confirms the legacy modules are absent. A Northstar implementation must pin either released v0.18.2 and use its documented APIs, or deliberately target the evolving v0.19 source API.

Official upstream is [git.cons.io/mighty-gerbils/gerbil](https://git.cons.io/mighty-gerbils/gerbil), identified as authoritative by `gerbil/README.md:25-35` and `gerbil/CONTRIBUTING.md:15-18`. Commit-pinned source links below use:

`https://git.cons.io/mighty-gerbils/gerbil/src/commit/4531c21b90fa6ee04f374af905ae3ddb9d89d590/<path>`

## 1. What NATS actually does in Northstar

The reference application is pinned at `c290e4c4f5f90e0fd45a2e38853259ab847f7994`.

Its only application-level NATS use is one JetStream key-value bucket:

- embedded server with JetStream and disk directory `data/nats`: `northstar/nats/nats.go:16-36`;
- bucket `todos`, compression enabled, one-hour TTL, 16 MiB total limit: `northstar/features/index/services/todo_service.go:24-50`;
- one JSON value per opaque session identifier: `todo_service.go:53-79,142-150,165-181`;
- reads are latest-value `Get`; missing entries receive seed state: `todo_service.go:53-75`;
- writes are unconditional `Put`, so concurrent requests are last-write-wins rather than compare-and-swap: `todo_service.go:142-150`;
- each SSE connection watches its own session key: `todo_service.go:86-88`, `northstar/features/index/handlers.go:32-70`;
- watcher updates are decoded and rendered to Datastar SSE; the nil initial-complete marker is ignored: `handlers.go:50-69`.

The pinned NATS client documents that default watch sends the latest value, then nil after initial values, followed by future updates; it uses an ordered consumer and a 256-entry application channel that deliberately blocks when full:

- `/home/jay/go/pkg/mod/github.com/nats-io/nats.go@v1.52.0/jetstream/kv.go:148-172,342-351`
- `kv.go:1187-1211,1246-1248,1280-1317`
- `kv.go:1335-1358`

Bucket defaults are history 1, file storage, one replica; TTL, maximum bytes, and compression map directly to the backing stream:

- `kv.go:209-270,619-687`
- `jetstream/stream_config.go:609-614`

Authoritative NATS references:

- [JetStream key-value store](https://docs.nats.io/nats-concepts/jetstream/key-value-store)
- [nats.go `jetstream.KeyValue`](https://pkg.go.dev/github.com/nats-io/nats.go/jetstream#KeyValue)

Therefore the replacement must cover four behaviors, not general distributed messaging:

1. session-keyed latest state;
2. one-hour expiration;
3. notification of every local successful write to current watchers;
4. optional restart persistence and storage limit.

## 2. Recommended in-process replacement semantics

### Preferred shape: one state actor plus subscriber channels

A single actor thread owns:

- `session-id -> {value, revision, expires-at}`;
- `session-id -> subscriber channels`;
- total serialized byte count if the 16 MiB limit matters.

HTTP handlers send commands to its mailbox or a bounded command channel and wait for a reply. This gives atomic read/modify/write and atomic “subscribe plus current snapshot,” eliminating the race between Northstar’s separate `Get` and `Watch`.

Each successful write:

1. replaces the latest value;
2. advances a revision;
3. refreshes expiry to one hour;
4. publishes the new immutable snapshot to subscribers in actor order.

This is materially stronger than Northstar’s current last-write-wins read/modify/put sequence. If exact concurrency behavior matters, retain unconditional replacement rather than revision checks.

### Alternative: mutex-protected hash plus per-key channels

This is smaller but easier to get wrong. Subscription registration and current-value capture must happen under the same mutex as writes. Never hold the state mutex while blocking on a slow subscriber.

### Persistence option

For exact restart persistence, use SQLite as the store of record and channels only for wake-up notification. Current Gerbil exposes SQLite opening, prepared statements, typed binds, and query rows:

- `gerbil/src/std/db/sqlite.ss:35-67,76-138,143-180`
- database transaction interface: `gerbil/src/std/db/interface.ss:16-41`
- upstream: [sqlite.ss at the inspected commit](https://git.cons.io/mighty-gerbils/gerbil/src/commit/4531c21b90fa6ee04f374af905ae3ddb9d89d590/src/std/db/sqlite.ss)

TTL can be represented by an `expires_at` column, enforced on reads and by a periodic delete. The event bus only sees writes made through the process; external database modifications are not automatically observable.

An in-memory hash replacement loses all sessions on restart and does not reproduce NATS file storage. That may be acceptable for a demo clone but is not semantically exact.

## 3. Delivery, ordering, backpressure, and failure

| Property | Northstar/NATS today | Practical Gerbil replacement |
|---|---|---|
| Value history | One latest revision by default | Store one latest snapshot |
| Initial watch delivery | Latest value, then nil marker | Atomically register and enqueue current snapshot |
| Ordering | Ordered consumer; per-key stream sequence | Single state actor establishes total write order |
| Durable subscriber | No; HTTP watcher is ephemeral | No; subscriber channel exists for SSE lifetime |
| Offline replay | Reconnect receives current latest, not intermediate history | Send current latest when subscribing |
| Writer acknowledgement | `Put` returns after JetStream publish/store | Reply after state/database commit and subscriber handoff policy |
| Subscriber buffer | NATS client channel capacity 256; callback blocks | Explicit bounded `make-channel n` |
| Slow SSE client | Eventually backs up watcher/NATS buffers | Choose block, disconnect, drop, or coalesce |
| Process failure | File-backed JetStream retains unexpired state | SQLite retains it; hash does not |
| Cross-process delivery | Available through NATS | Intentionally absent |

Gerbil channels are FIFO queues protected by a mutex:

- queue append/dequeue: `gerbil/src/std/struct/queue.ss:37-74`;
- bounded put blocks or times out; try-put returns false: `gerbil/src/std/sync/channel.ss:30-63`;
- get blocks or times out: `channel.ss:77-115`;
- close wakes waiters, drains queued values, then returns EOF: `channel.ss:117-132`;
- documentation of the same semantics, under the stale v0.18 import name: `gerbil/doc/reference/std/misc/channel.md:8-20,76-122,202-215,301-326`.

Backpressure must be selected explicitly:

- **Block:** preserves every update but one slow client can delay the state actor if publishing occurs synchronously.
- **Disconnect slow subscriber:** bounded memory and clear failure, suitable for SSE because reconnect can receive current state.
- **Drop newest/oldest:** bounded and responsive but can leave a client stale.
- **Coalesce latest:** capacity-one mailbox with replacement; best fit because every event renders the complete todo model and reconnect semantics are latest-state oriented.

For Northstar, coalescing or disconnecting slow clients is safer than unbounded queues. Intermediate todo states are not durable user-visible records.

Raw Gambit thread mailboxes are unbounded FIFO queues: `gerbil/src/gambit/lib/_thread.scm:3255-3361,3381-3420`. They provide no producer backpressure. Use a bounded `:std/sync/channel` for potentially high-volume ingress.

## 4. HTTP server and routing

### Current v0.19 source API

Import `:std/net/http/server`. Its API re-exports server control, request/response interfaces, static muxes, statuses, and closure/file/directory handlers:

- `gerbil/src/std/net/http/server/api.ss:4-19`
- [server API source](https://git.cons.io/mighty-gerbils/gerbil/src/commit/4531c21b90fa6ee04f374af905ae3ddb9d89d590/src/std/net/http/server/api.ss)

`ServerConfig` supplies mux, log sink, listeners, connection limit, buffers, and request/response timeouts. Defaults include 1,024 connections, 32 KiB buffers, 30-second request timeout, and 120-second output timeout:

- `gerbil/src/std/net/http/server/interface.ss:82-108`

Server control supports `start!`, `stop!`, `restart!`, current configuration, and active connection count:

- `interface.ss:111-132`

A request contains parsed URL, protocol, method string, headers, body reader, client address, and logger:

- `interface.ss:11-27`
- body readers support both `Content-Length` and chunked requests without the v0.18 POST/PUT-only limitation: `gerbil/src/std/net/http/server/request.ss:21-54`.

### Routing

`new-static-mux` supports:

- exact `path:` rules;
- prefix `rest:` rules;
- filesystem `file:` and `dir:` rules;
- arbitrary `StaticRule` predicates.

Evidence: `gerbil/src/std/net/http/server/mux/static.ss:10-54,57-82`.

Built-in matching is path-only. It does not supply Chi-style method dispatch, path-variable extraction, middleware stacks, or route groups. A Northstar router can use custom `StaticRule` predicates inspecting `Request-method` and `Request-url`, then parse `{mode}` and `{idx}` segments itself. First-match rule order is significant.

### Version warning

`gerbil/doc/reference/std/net/httpd.md:1-141` describes the released v0.18 `:std/net/httpd` API, but `src/std/net/httpd.ss` is absent at HEAD. Existing research about `http-response-begin/chunk/end` remains valid only for v0.18.2, not for this v0.19 checkout.

## 5. Server-Sent Events

No Gerbil SSE-specific helper was found. Native HTTP chunked streaming is sufficient.

`ResponseHandler.begin!` returns a `BufferedWriter`; headers are emitted and flushed immediately:

- `gerbil/src/std/net/http/server/interface.ss:35-61`
- `gerbil/src/std/net/http/server/request.ss:143-183`

The outer returned writer is buffered, so each complete SSE event must be followed by its `flush` operation. The underlying chunked writer flushes each non-empty HTTP chunk and emits the terminating zero chunk on close:

- `gerbil/src/std/net/http/common/chunked.ss:87-116`
- exact framing tests: `gerbil/src/std/net/http/common/chunked-test.ss:10-47`.

Practical stream lifecycle:

1. `res.begin!` with `Content-Type: text/event-stream`, cache policy, and any Datastar headers.
2. Keep the HTTP handler active for the entire subscription.
3. Read subscriber channel events.
4. write complete UTF-8 SSE frames and flush after each;
5. in `unwind-protect`/`finally`, unregister the subscriber and close the writer.

Current constraints:

- There is no public peer-disconnect callback or request cancellation token.
- Disconnect is detected when a socket write/flush fails or when server shutdown closes the socket.
- Response output timeout limits blocked writes, not total stream lifetime.
- The server automatically negotiates gzip/deflate and configures streaming compression with flush enabled: `request.ss:146-183`.
- The default response adds `Connection: close`, and the current server handles one request per accepted connection: `request.ss:67-75`, `server.ss:192-260`.
- An empty application write produces no chunk; use a non-empty SSE comment for heartbeat: `chunked.ss:91-100`.
- Last-Event-ID replay, retry policy, and Datastar event serialization remain application/library responsibilities.

On an exception after streaming has begun, the server’s attempt to write a 500 response cannot replace the already-started response; the outer handler closes the connection. Stream cleanup must therefore be local and idempotent: `server.ss:233-260`, `request.ss:77-86`.

## 6. Actors, threads, mailboxes, and channels

Actor threads created by `spawn` unwind finalizers on uncaught exceptions; plain `spawn-thread` does not add that actor wrapper:

- `gerbil/doc/reference/gerbil/runtime/thread-primitives.md:1-57`.

Thread groups, joins, termination inspection, group kill, and asynchronous abort are documented at:

- `gerbil/doc/reference/std/misc/threads.md:35-127,153-224`.

For this application:

- use one actor thread for state serialization;
- use bounded channels for subscriber queues and optionally for the command queue;
- retain thread handles and join them during shutdown;
- use `unwind-protect` around every subscription and SSE writer.

The v0.18 `:std/actor` documentation describes request/reply envelopes, selective receive, expiry, tickers, shutdown messages, and monitors:

- `gerbil/doc/reference/std/actor.md:15-47,67-110,377-442`.

However, `src/std/actor.ss` is absent at current HEAD. The new `:std/ensemble` actor system is not a sensible local replacement yet: its broadcast implementation is literally `TODO` at `gerbil/src/std/ensemble/broadcast/broadcast.ss:1-11`. Do not base Northstar on it merely to emulate NATS.

## 7. Timers and scheduling

Current low-level facilities are:

- `thread-sleep!`;
- timed `thread-receive`;
- timed `channel-put`/`channel-get`;
- `InexactTime`, `CoarseTime`, and `PreciseTime`;
- relative/absolute timeout conversion.

Evidence:

- `gerbil/src/std/time/time.ss:6-21`
- `gerbil/src/std/time/precise.ss:15-64`
- `gerbil/src/std/time/timeout.ss:8-63`
- documented synchronization uses: `gerbil/doc/reference/std/misc/timeout.md:8-32`.

No current general scheduler or timer wheel was found. Material options are:

1. **Lazy TTL:** check expiry on read/write/subscribe; simplest and enough for correctness.
2. **One sweeper thread:** timed mailbox receive wakes periodically, removes expired sessions, and can stop immediately when a shutdown message arrives.
3. **Per-session timer thread:** simple but scales poorly.
4. **Central priority queue:** useful only if exact near-real-time expiry for many keys becomes necessary.

A sweeper should derive expiry from a monotonic/absolute deadline where possible. Wall-clock persisted timestamps are still needed across restart.

## 8. Publish/subscribe and event bus

### Project-owned bus: recommended

Implement a small topic/key registry around `:std/sync/channel`. This keeps policy explicit:

- bounded queue size;
- snapshot-on-subscribe;
- per-key ordering;
- slow-consumer handling;
- unregister and close behavior;
- shutdown fan-out.

### Existing v0.19 ensemble event bus: precedent, not dependency

Gerbil contains an internal event bus that:

- stores a channel per subscriber;
- copies every event to every channel;
- closes all channels at shutdown.

Evidence:

- interface: `gerbil/src/std/ensemble/interface/host.ss:20-34`;
- implementation: `gerbil/src/std/ensemble/host/bus.ss:13-55`.

It uses default unbounded channels (`make-channel` with no limit), so slow consumers grow memory. Concurrent emitters are not serialized across the complete subscriber loop, meaning different subscribers can theoretically observe different interleavings. Closed subscribers are removed only after a later emit. It is coupled to ensemble internals and is not documented as an independent public bus.

The separate ensemble broadcast interface advertises groups and subscriptions, but its implementation is incomplete. It is not a viable NATS substitute in this checkout.

## 9. Supervision and shutdown

The HTTP server creates its own thread group, tracks listeners and active sockets, and enforces a maximum connection count:

- `gerbil/src/std/net/http/server/server.ss:27-48,70-107,150-165`.

`stop!`:

1. closes listener and active connection sockets;
2. waits up to three seconds for listener/handler removal;
3. forcibly terminates remaining threads;
4. stops the configured log sink.

Evidence: `server.ss:114-138`.

This is suitable for terminating SSE streams but is not a graceful drain with an arbitrary application deadline. Application shutdown should first prevent new mutations, close subscription channels, stop the HTTP server, stop/join the state and sweeper actors, close SQLite, and then stop owned logging sinks.

The current checkout has no active `:std/os/signal-handler`; its old implementation is under `src/v0.19-WIP/`. Process signal integration is therefore an unresolved v0.19 gap. An executable can still expose an explicit shutdown entry point, but SIGINT/SIGTERM behavior must be verified against the selected Gerbil release rather than inferred from stale docs.

## 10. Configuration

The v0.18 reference documents plist configuration with schema checking at `gerbil/doc/reference/std/config.md:1-40,42-126`, but `src/std/config.ss` is absent at current HEAD.

Current reliable facilities are:

- primitive `getenv` from the Gerbil/Gambit runtime;
- `:std/cli/getopt` for flags, options, commands, defaults, and typed conversion:
  - `gerbil/src/std/cli/getopt.ss:11-26,56-122`;
  - `gerbil/doc/reference/std/cli/getopt.md:1-47,95-115`.
- project-owned typed configuration records.

There is no verified built-in `.env` loader. Northstar’s `HOST`, `PORT`, `LOG_LEVEL`, and `SESSION_SECRET` should be read explicitly with defaults and validation. Production must reject the demo default session secret if signed cookies are retained.

## 11. Logging

Import `:std/log`.

Current records are structured values containing timestamp, numeric level, source, message, and an alist of fields:

- `gerbil/src/std/log/interface.ss:8-27`.

`deflogger` creates per-source structured and formatted logging macros:

- `gerbil/src/std/log/user.ss:11-46`;
- record construction: `gerbil/src/std/log/macros.ss:44-59`.

The system logger is an asynchronous thread receiving records through its unbounded mailbox and dispatching them to configured sinks after level filtering:

- `gerbil/src/std/log/system.ss:14-40,57-109,111-161`.

Available sinks include console/stderr and rotating compressed files:

- console: `gerbil/src/std/log/console.ss:11-57`;
- rotation size/backlog/flush/filter customization: `gerbil/src/std/log/rotate.ss:18-49,53-76,128-175`;
- environment/source level configuration: `gerbil/src/std/log/level.ss:19-46,75-125`.

Limits and differences from Northstar:

- default line output is plaintext, not JSON: `gerbil/src/std/log/format.ss:11-18`;
- async logger mailboxes are unbounded;
- no automatic Chi-style access log middleware exists;
- a JSON formatter can be supplied to the rotating sink’s `write` procedure, but console JSON needs a custom sink.

## 12. Static assets

Current HTTP server handlers support:

- exact files;
- caching small files;
- directory trees with `index.html`;
- MIME type lookup;
- path normalization against the configured base directory.

Evidence:

- `gerbil/src/std/net/http/server/handlers/file.ss:24-38,39-98`;
- `gerbil/src/std/net/http/server/handlers/directory.ss:19-63`;
- mux `file:`/`dir:` rules: `gerbil/src/std/net/http/server/mux/static.ss:41-50`.

Limitations:

- range requests are TODO: `file.ss:38`;
- no built-in ETag, immutable fingerprint policy, or cache-control policy is shown;
- directory listing is TODO: `directory.ss:24-26`.

For Northstar-style embedded assets, `:std/source` offers `this-source-content`, which reads an ancillary file at expansion time and burns its bytes into the object file:

- `gerbil/src/std/source.ss:20-30,54-58`;
- `gerbil/doc/reference/std/source.md:90-103`.

Options:

1. serve filesystem assets through `dir:` during development;
2. embed each production asset with `this-source-content` and return it from an exact route;
3. generate a project-owned embedded asset table at build time.

## 13. JSON

Import `:std/encoding/json`.

Current facade correspondence is:

- JSON null ↔ void;
- arrays ↔ lists/vectors;
- objects ↔ string/symbol keyed hash tables or ordered weak alists;
- UTF-8 strings and byte vectors are supported.

Evidence:

- type correspondence: `gerbil/src/std/encoding/json.ss:3-18`;
- public read/write/string/byte API: `gerbil/src/std/encoding/json/api.ss:9-29`;
- scalar, Unicode, array, object, ordering, and error tests:
  `gerbil/src/std/encoding/json/json-test.ss:47-156,157-260`.

The current names are `string->json`, `json->string`, `u8vector->json`, and `json->u8vector`, not the v0.18 names in `doc/reference/std/text/json.md`.

Use an explicit JSON object representation and options rather than depending on defaults, because defaults changed between v0.18.2 and v0.19.

## 14. Cryptography and random identifiers

Current cryptographic random bytes are provided by `:std/crypto/random` over OpenSSL `RAND_bytes`/`RAND_priv_bytes_ex`:

- `gerbil/src/std/crypto/random.ss:1-20`;
- FFI implementation: `gerbil/src/std/crypto/libcrypto.ss:274-283,486-488`;
- released documentation: `gerbil/doc/reference/std/crypto.md:842-854`.

For opaque session identifiers, generate at least 16 random bytes and encode them with URL-safe, unpadded Base64. Gerbil’s own temporary-name implementation demonstrates exactly that shape:

- `gerbil/src/std/io/tempfile.ss:58-76`;
- URL-safe Base64 behavior: `gerbil/src/std/encoding/base64.ss:18-37`.

The documented `:std/misc/uuid` source is absent from v0.19 HEAD. Random opaque Base64 identifiers are also closer to Northstar’s `NextEncodedID` than textual UUIDs.

HMAC-SHA-256/384/512 exists:

- `gerbil/src/std/crypto/hmac.ss:9-36`.

There is no verified constant-time comparison helper or complete signed-cookie/session middleware in current stdlib. The simplest secure model is an unguessable opaque cookie whose state remains server-side. If client-contained signed sessions are required, cookie serialization, HMAC verification, rotation, and constant-time comparison need a project or ecosystem implementation.

## 15. Testing

Gerbil’s test library provides suites, cases, equality/predicate checks, captured output, and expected-exception checks:

- `gerbil/doc/reference/std/test.md:1-41,96-115`.

Runner conventions:

- files end in `-test.ss`;
- exported suites end in `-test`;
- optional `test-setup!` and `test-cleanup!` wrap the module, with cleanup protected;
- file, directory, and recursive `...` discovery are supported.

Evidence:

- `gerbil/doc/reference/dev/test.md:1-25`;
- current discovery and filtering implementation:
  `gerbil/src/tools/gxtest.ss:16-42,44-67,69-106,108-149`.

Current first-party HTTP tests demonstrate full in-process server setup/cleanup, exact and chunked handlers, body echo, and a 1 MiB payload:

- `gerbil/src/std/net/http/http-test.ss:9-45,50-65,67-98`.

Chunk framing has exact byte-level tests at `gerbil/src/std/net/http/common/chunked-test.ss:10-58`; channels have concurrent buffering/ordering tests at `gerbil/src/std/sync/channel-test.ss:10-101`.

Northstar-specific tests should cover:

- atomic subscribe plus initial snapshot;
- write order and reconnect-latest behavior;
- TTL refresh and expiry;
- 16 MiB policy;
- slow-consumer block/disconnect/coalesce behavior;
- subscriber removal after SSE disconnect;
- state actor failure propagation;
- restart persistence when SQLite is selected;
- headers visible before first SSE event;
- multiple UTF-8 events and explicit flush;
- heartbeat comments;
- abrupt peer close and shutdown cleanup;
- static path traversal rejection;
- JSON representation stability;
- random identifier length/uniqueness shape.

## 16. Material implementation options

### A. State actor + in-memory hash + bounded/coalescing subscribers

Best operational simplicity and strongest local ordering.

**Tradeoff:** no restart persistence unless snapshots are added.

### B. State actor + SQLite + bounded/coalescing subscribers

Closest NATS replacement: durable latest state, transaction boundary, local watch fan-out, explicit TTL.

**Tradeoff:** schema and cleanup work; notification only covers writes through the actor.

### C. Mutex hash/SQLite + direct per-key channels

Least code for a small demo.

**Tradeoff:** harder to make read-modify-write and subscribe-snapshot atomic; blocking fan-out can deadlock or stall unrelated sessions.

### D. v0.19 ensemble actors/event bus

Not recommended. It adds distributed-system machinery while broadcast is incomplete and its internal event bus is unbounded.

### E. Keep embedded NATS

Preserves current semantics most literally but retains a large dependency and background server for a single-process application.

## 17. Risks, gaps, and confidence

### High

- The checkout is unreleased v0.19 development while its reference manual largely describes v0.18 APIs.
- No built-in current public configuration module, signal handler, UUID module, SSE helper, session middleware, or complete general pub/sub service was found.
- In-memory state is not equivalent to Northstar’s file-backed JetStream persistence.
- Slow-consumer policy must be selected explicitly; default unbounded channels can leak memory.

### Medium

- Current HTTP API has little matching documentation; source is the authority.
- Disconnect timing is transport-dependent and only observed during output or shutdown.
- Current logging is structured internally but not JSON on the wire.
- Cookie authentication requires more than HMAC primitives.
- The inspected Gerbil checkout contains pre-existing modifications in generated Gambit files; cited stdlib files were not modified.

### Confidence

- **High:** Northstar’s concrete NATS responsibilities and watcher semantics.
- **High:** current Gerbil source behavior for HTTP, channels, logging, JSON, assets, crypto, SQLite, and tests at the pinned commit.
- **Medium:** stability of these v0.19 APIs until a release is cut.
- **Medium:** exact cross-platform socket disconnect exception/timing.
- **Low:** treating stale `doc/reference` import names as valid against HEAD; they are demonstrably absent.

## 18. Evidence-backed validation commands

No test was run during this read-only research. The installed tool reports `Gerbil v0.19-dev-31-g4a4d1a30`, one commit behind the inspected source checkout, so executing source tests against it would not validate exact HEAD.

After building this checkout, focused upstream validation is:

```sh
cd /home/jay/Code/workbench-gerbil/gerbil

./build.sh env gerbil test src/std/sync/channel-test.ss
./build.sh env gerbil test src/std/net/http/common/chunked-test.ss
./build.sh env gerbil test src/std/net/http/http-test.ss
./build.sh env gerbil test src/std/encoding/json/json-test.ss
./build.sh env gerbil test src/std/crypto/cipher-test.ss
./build.sh env gerbil test src/std/db/sqlite-test.ss
```

Full upstream validation established by `gerbil/CONTRIBUTING.md:172-189`:

```sh
cd /home/jay/Code/workbench-gerbil/gerbil
make check
# documented alternative:
./build.sh env gerbil test ./...
```

Future Northstar package validation:

```sh
cd /home/jay/Code/workbench-gerbil/<northstar-package>
gerbil build
gerbil test path/to/state-test.ss
gerbil test path/to/sse-integration-test.ss
gerbil test ./...
```

These should run under the same pinned Gerbil build used to compile the application.