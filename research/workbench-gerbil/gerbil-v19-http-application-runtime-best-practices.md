# Gerbil v19 HTTP Application Runtime Best Practices

## Executive finding

At Gerbil commit `4531c21b90fa6ee04f374af905ae3ddb9d89d590`, the supported embedded server API is `:std/net/http/server`, centered on public `Server`, `ServerConfig`, `ServerMux`, `RequestHandler`, and `ResponseHandler` interfaces.

**Recommended one-process architecture:** start Tuna’s serialized command runtime first, then start the HTTP server. Let concurrent HTTP handler threads submit bounded commands to the Tuna runtime and wait for completion when a response depends on the result. Never execute authoritative state transitions directly in HTTP threads, and do not attempt to merge an application event loop with the server: the server exposes no public event loop and already owns listener and connection actor threads.

## Version and documentation status

- The inspected Gerbil checkout is exactly commit `4531c21b`.
- The new v19 HTTP server first appeared in commit `9e207a00` and is publicly re-exported by `src/std/net/http/server.ss:1-5` through `src/std/net/http/server/api.ss:1-19`.
- `doc/reference/std/net/httpd.md:1-50` and `doc/tutorials/httpd.md:33-65` describe the older `:std/net/httpd` API and thread-valued server. They are not authoritative for the v19 `Server` interface.
- Likewise, `doc/reference/std/net/address.md:3-45` still documents pair-based addresses, while v19 uses typed address structures in `src/std/net/address/types.ss:21-50`.

## Public API and supported semantics

### `ServerConfig`

`ServerConfig` has three required fields and the following defaults:

| Field | Semantics/default |
|---|---|
| `mux` | Required `ServerMux` |
| `log` | Required `LogSink` |
| `listen` | Required address list |
| `sockopts` | `default-listen-sockopts` |
| `backlog` | `default-listen-backlog` |
| `max-connections` | 1024 |
| `max-request-line` | 1024 bytes |
| `max-headers` | 32768 bytes |
| `request-buffer` | 32768 bytes |
| `response-buffer` | 32768 bytes |
| `request-timeout` | 30 seconds |
| `response-timeout` | 120 seconds |

Evidence: `src/std/net/http/server/interface.ss:82-109`; socket defaults are `src/std/io/socket/api.ss:22-38`.

Treat a supplied configuration as immutable while running. The server stores it by reference (`src/std/net/http/server/server.ss:39-48`), while `config` returns only a shallow structure copy (`server.ss:145-148`). Use public `restart!` with a new configuration instead of mutating shared fields.

### `Server`

Public operations are:

- `start!`
- `stop!`
- `active-connections`
- `config`
- `restart!`

Evidence: `src/std/net/http/server/interface.ss:111-133`; implementation binding at `src/std/net/http/server/server.ss:262-267`.

Behavior:

- `start!` is idempotent while running and returns after binding sockets and spawning listeners; it is not the application’s blocking run loop (`server.ss:50-54,70-112`).
- Startup failure logs, closes partially created resources, and rethrows (`server.ss:92-112`).
- `stop!` is idempotent when stopped, but is abortive rather than graceful: it closes listening and active client sockets, waits up to approximately three seconds, then forcibly terminates remaining listener/handler threads (`server.ss:56-60,114-138`).
- `restart!` stops if necessary, replaces the configuration, and starts again (`server.ss:62-68`).
- `active-connections` is the number of accepted sockets currently registered, not an HTTP request counter or application-command count (`server.ss:140-143`).

### Listener and request concurrency

For every configured address:

1. `start!` creates a server socket.
2. It spawns one named listener actor in the server thread group.
3. Each accepted connection gets one named handler actor.
4. `max-connections` is checked against the active handler-socket table; excess connections are closed without an HTTP response.

Evidence: `src/std/net/http/server/server.ss:70-90,150-166`. `spawn/name` inherits the caller’s thread group, so connection handlers remain in the listener/server group: `src/gerbil/runtime/thread.ss:27-54`.

The implementation invokes `handle-next-request!` exactly once and then closes the connection (`server.ss:248-260`). It also emits `Connection: close` by default (`src/std/net/http/server/request.ss:67-75`). Therefore v19 does **not** provide persistent HTTP/1.1 keep-alive or pipelined requests. In practice there is one handler actor per request because each connection serves only one request.

Blocking inside one handler—including waiting for a Tuna command or streaming Server-Sent Events (SSE)—occupies that connection actor and one `active-connections` slot, but does not block listener acceptance or unrelated handlers.

### Route multiplexing

`new-static-mux` is the supplied public mux:

- `path:` matches an exact URL path.
- `rest:` matches the path itself or descendants separated by `/`.
- Rules are evaluated in declaration order.
- No match returns the predefined 404 handler.
- Matching uses `Request.url.path`; host and method dispatch are not built in.

Evidence: `src/std/net/http/server/mux/static.ss:21-40,57-82`.

For a custom mux, implement the public `ServerMux.request-handler` interface and always return a handler, including for 404 (`interface.ss:73-80`). Because lookups happen concurrently in handler threads, mutable custom mux state must be synchronized.

**High-severity v19 limitation:** the `file:` and `dir:` shorthand patterns lack a tail binding and recurse using the unchanged outer list (`mux/static.ss:41-50`). Avoid those shorthands. Use explicit `path:`/`rest:` rules with public `new-file-handler` or `new-directory-handler`.

### `RequestHandler`

A `RequestHandler` must call exactly one response operation before returning:

```scheme
(handle-request! request response)
```

Evidence: `src/std/net/http/server/interface.ss:63-71`.

Use public `new-closure-handler` to wrap an application procedure (`src/std/net/http/server/handlers/closure.ss:6-19`).

The request exposes URL, protocol, method, headers, buffered body reader, peer address, and logger (`interface.ss:11-20`). Request bodies support fixed `Content-Length`, chunked transfer encoding, or an empty reader (`request.ss:21-54`).

### `ResponseHandler` and ownership

Public response choices are:

- `write!`: complete byte-vector response.
- `begin!`: begin a chunked response and return a `BufferedWriter`.
- `redirect!`: internal server redispatch.
- `upgrade!`: switch protocol and return the connection context.
- `proxy!`: return the connection context.

Evidence: `src/std/net/http/server/interface.ss:35-61`.

The response is owned by the current handler’s dynamic extent:

- A second normal action raises “already acted on output” (`request.ss:77-86,90-145`).
- After the handler returns or raises, the server closes the request body and response (`server.ss:233-246`).
- It then closes the buffered reader, writer, and socket and unregisters the connection (`server.ss:248-260`).

Therefore, do not retain a response or streaming writer after the handler returns. Do not hand it to a detached producer thread. If another thread produces data, the request handler must remain alive, serialize access, and close/join that work before returning; the simpler supported model is to write from the handler actor itself.

`write!` requires a byte vector, not a string (`interface.ss:38-42`). It closes the response writer after completing the body (`request.ss:90-142`).

### Streaming and SSE

`begin!` writes chunked headers, flushes them, and returns a buffered writer (`request.ss:143-183`). Closing that writer ends the chunked response; at commit `4531c21b`, the chunk terminator is correctly `0\r\n\r\n` (`src/std/net/http/common/chunked.ss:102-116`; tested at `src/std/net/http/common/chunked-test.ss:10-47`).

For SSE:

- Keep the handler alive for the stream’s entire lifetime.
- Flush the returned outer `BufferedWriter` after each SSE event.
- Close it on client disconnect or application shutdown.
- Count each SSE client against `max-connections`.
- Expect `server.stop!` to close its socket and, after the deadline, terminate a handler still blocked on an unrelated application channel.

Streaming automatically negotiates gzip/deflate when the request advertises it (`request.ss:146-183`). v19 has no clear public per-response switch to disable automatic compression. This is a limitation for SSE deployments that require strict identity encoding; supplied headers would merely duplicate the implementation-generated `Content-Encoding` header.

### Exceptions and cleanup

Handler exceptions are logged. If no response has started, the server attempts an empty 500 response (`server.ss:233-246`). If the handler throws after `write!`/`begin!`/`upgrade!`, that fallback is a second response action and can itself fail; the outer handler guard logs and closes the connection (`server.ss:248-260`). Application code should map expected failures before starting a response.

Listener handling:

- `OSError` is logged and accept retries.
- `Closed` unregisters normally.
- Any other exception logs and unregisters the listener.

Evidence: `server.ss:168-190`.

**Medium-severity v19 limitations:**

- `upgrade!` emits misspelled `Connection: ugrade` and the returned connection is still closed when the handler returns (`request.ss:188-197`; `server.ss:244-260`).
- `proxy!` does not mark the response acted and has no independent lifetime transfer (`request.ss:198-209`).
- There is no graceful “stop accepting, drain indefinitely” API; `stop!` closes active sockets immediately and forces termination after its deadline.
- There is no public listener-thread or handler-thread access. Do not reach into `http-server`, `server-listener`, `server-handler`, listener/handler hash tables, or `##` implementation procedures.

## `InetAddress` for configurable loopback binding

The public `:std/net/address` module exports `InetAddress`, `localhost4`, `localhost6`, `string->address`, and `address->string` (`src/std/net/address/api.ss:1-25`).

Preferred construction when the family is selected explicitly:

```scheme
(InetAddress localhost4 port)
(InetAddress localhost6 port)
```

The constructor requires an `IPAddress` and a fixnum port from 0 through 65535 (`src/std/net/address/types.ss:79-81,97-103`). Loopback constants are defined at `types.ss:117-124`.

For text configuration, `string->address` requires the canonical domain prefix:

```text
inet4:127.0.0.1:8080
inet6:::1:8080
```

Evidence: `src/std/net/address/parser.ss:185-217,237-262`; canonical formatting at `src/std/net/address/stringer.ss:67-72,99-102`.

A bare `127.0.0.1:8080` is rejected in v19. `dns:localhost:8080` produces a `DNSAddress`, but the HTTP listener calls `tcp-listen`, whose public contract requires `InetAddress` (`src/std/io/socket/api.ss:40-56`). For a loopback-only application, parse the configured host/port into a canonical address, verify `InetAddress?`, verify the address is permitted loopback, and reject DNS/non-loopback values before constructing `ServerConfig`.

The server implementation accepts either an `InetAddress` or canonical string for plaintext listeners, plus TLS forms (`server.ss:92-105`), but direct validated `InetAddress` values are less ambiguous.

## Tuna state-machine integration

Tuna already provides the correct concurrency boundary:

- The runtime owns one command worker (`tuna/lib/runtime.ss:229-263`).
- Authoritative state installation rejects any thread other than that owner (`runtime.ss:132-153`).
- Producers submit through a bounded channel and receive `accepted`, `full`, or `not-running` (`runtime.ss:279-306`).
- Accepted commands expose completions for waiting (`runtime.ss:308-310`).

Consequently:

1. HTTP handler actors may validate/decode requests concurrently.
2. Mutating requests must call `command-runtime-submit-transition!` or another public runtime submission API.
3. If the response depends on the result, the same handler waits on the command completion.
4. Map `full` and `not-running` to explicit HTTP overload/shutdown responses.
5. Read-only routes may use the synchronized `command-runtime-snapshot`; they must treat the returned state as immutable.
6. Do not invoke installation logic or emulate the serialized worker in HTTP threads.
7. Do not submit nested runtime work from a transition; Tuna already warns that nested submission is invalid (`tuna/README.md:225-231`).

There is no server event loop to merge with Tuna. `Server.start!` spawns its own actors and returns. Merging would defeat Tuna’s ownership invariant without providing any Gerbil-supported benefit.

## Running until shutdown and signals

Tuna’s existing executable starts its runtime and waits using `command-runtime-wait!`, with orderly stop/join and logging cleanup in `finally` blocks (`tuna/main.ss:11-31`). Its timed `thread-join!` loop deliberately avoids Gambit’s deadlock detector while the runtime is idle (`tuna/lib/runtime.ss:369-382`). Retain this mechanism—or an equivalent application-owned lifecycle completion—as the main-thread blocker. A `Server` is not a thread, so `thread-join!` on it is invalid.

For one-process lifecycle:

1. Initialize logging and application state.
2. Start Tuna’s command runtime.
3. Construct and `start!` the HTTP server.
4. Block the primordial thread on Tuna’s lifecycle wait/completion.
5. On shutdown, stop command admission and wake/close SSE subscriptions, allow accepted commands to drain, then call `server.stop!`.
6. Join Tuna’s worker.
7. Shut down logging last, as Tuna already does (`tuna/lib/log.ss:23-30`).

The exact ordering may require an application-owned stream-shutdown notification because v19 lacks a graceful listener-only stop.

### Signal support

- `current-user-interrupt-handler` is a public Gerbil runtime binding (`src/gerbil/core/runtime.ss:495-510`) and is installed by Gerbil during runtime initialization (`src/gerbil/runtime/init.ss:193-204,237-238`).
- Gambit documents user interrupts, typically Ctrl-C, and the handler parameter at `src/gambit/doc/gambit.txi:2205-2226,5505-5508`.

An application may dynamically bind this public handler to post a shutdown notification or call the nonblocking Tuna stop request, allowing the main lifecycle path to perform cleanup. The interrupt handler should not itself perform prolonged server shutdown.

**High-severity limitation:** general POSIX signal modules are not available in the v19 standard-library tree. Stale documentation still advertises `:std/os/signal-handler` (`doc/reference/std/os/signal-handler.md:1-18`), but its implementation is quarantined under `src/v0.19-WIP/v0.19-TODO-std/os/signal-handler.ss:1-31`, not `src/std/os`. Do not import, copy, vendor, or reach into that TODO implementation. There is therefore no supported v19 standard-library SIGTERM callback suitable for systemd shutdown. Without application changes, Tuna’s documented Ctrl-C interruption remains the only existing interactive shutdown path (`tuna/README.md:42-56`), and SIGTERM should be regarded as potentially abrupt.

## Public-only integration sketch

```scheme
(import :std/interface
        :std/log
        :std/net/address
        :std/net/http/server
        :tuna/lib/runtime)

(def address (InetAddress localhost4 configured-port))
(def mux
  (new-static-mux
   path: "/command" (new-closure-handler command-handler)
   rest: "/events" (new-closure-handler sse-handler)))

(using (server
        (new-http-server
         (ServerConfig
          mux: mux
          log: application-log-sink
          listen: [address]))
        : Server)
  ;; Runtime must already be running before admission begins.
  (server.start!)
  ;; Block on Tuna/application lifecycle, not on SERVER.
  (command-runtime-wait! runtime)
  (server.stop!))
```

No private `http-server` fields, raw sockets, internal request constructors, listener functions, thread tables, TODO signal modules, or `##` procedures are needed.

## Validation

### Focused commands

After rebuilding this exact checkout:

```sh
cd /home/jay/Code/workbench-gerbil/gerbil
./build.sh env gerbil test \
  src/std/net/http/common/chunked-test.ss \
  src/std/net/http/http-test.ss
```

For Tuna’s runtime contract:

```sh
cd /home/jay/Code/workbench-gerbil/tuna
test/run-command-runtime-matrix.sh
```

### Full Gerbil validation

```sh
cd /home/jay/Code/workbench-gerbil/gerbil
make check
# documented equivalent:
./build.sh env gerbil test ./...
```

These commands are authoritative from `CONTRIBUTING.md:182-189` and `doc/reference/dev/test.md:17-24`.

The available compiled runtime reported `v0.19-dev-31-g4a4d1a30`, older than source commit `4531c21b`; therefore exact-commit runtime tests were not claimed. Rebuild before validation.

## Confidence and residual gaps

Confidence is **high** for public interfaces, concurrency, address parsing, ownership, cleanup, and lifecycle behavior because each is directly traced to commit `4531c21b` source. Confidence is **medium** for operational behavior under forced termination and user interrupts because no exact-commit rebuilt runtime was available.

Residual gaps:

- No test covers static mux `file:`/`dir:` shorthand, upgrade/proxy lifetime, handler failure after streaming begins, SSE shutdown, or the three-second forced-stop path.
- No supported v19 SIGTERM handler exists.
- No graceful listener quiesce/drain API exists.
- The checked-in HTTP and address reference manuals lag behind the new v19 APIs.