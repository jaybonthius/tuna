# Tuna browser-terminal server mechanics

**Research baseline:** Gerbil Datastar working tree at `a0d020c`; SSE package at `1a8609e`; Tuna at `46783db`; installed Gerbil `v0.19-dev-31-g4a4d1a30`; active Gerbil source checkout `v0.19-dev-32-g4531c21b`.

## Conclusion and recommendation

The minimal loop is supported, with one blocker:

1. Register path-specific Gerbil handlers for `/` and `/subscribe`; dispatch `GET /` versus `POST /` inside the root handler because `new-static-mux` matches paths, not methods.
2. `GET /` returns ordinary HTML containing Datastar v1.0.2, `data-init="@get('/subscribe')"` and one `<pre id="state">`.
3. `POST /` validates a Datastar JSON body, translates it into a fixed application-defined Tuna request, submits it through `command-runtime-submit-transition!`, and returns an empty `204 No Content` only when admission is `accepted`.
4. `GET /subscribe` creates one Tuna state subscription per connection, opens one `call-with-datastar-sse` response, sends the initial snapshot, then rereads and fat-morphs the entire `<pre id="state">` after invalidations. No additional application broadcaster is needed: Tuna already fans out coalesced invalidations to per-subscriber capacity-one channels.
5. Add periodic writes or heartbeats because neither Gerbil nor these libraries expose immediate peer-disconnect notification while the handler is blocked.
6. **Blocker:** deploy against Gerbil `4531c21b` or later. The installed/pinned dev31 runtime terminates chunked responses incorrectly and fails official Datastar conformance.

**Confidence:** High for the public APIs, framing, Tuna fanout and threading behavior; medium for production lifecycle behavior until the full suite runs against a Gerbil build containing the chunked-terminator fix.

## 1. Gerbil routing and method handling

`new-static-mux` accepts path rules only; `match-path` compares `Request-url.path`, while closure handlers call an ordinary `(request response)` procedure:

- `gerbil/src/std/net/http/server/mux/static.ss:21-60`
- `gerbil/src/std/net/http/server/handlers/closure.ss:8-19`
- Authoritative source:
  - <https://git.cons.io/mighty-gerbils/gerbil/src/commit/4531c21b90fa6ee04f374af905ae3ddb9d89d590/src/std/net/http/server/mux/static.ss>
  - <https://git.cons.io/mighty-gerbils/gerbil/src/commit/4531c21b90fa6ee04f374af905ae3ddb9d89d590/src/std/net/http/server/handlers/closure.ss>

Therefore the exact route shape is:

- `path: "/"` → one closure that branches on `(Request-method request)`:
  - `"GET"`: initial page.
  - `"POST"`: Tuna command submission.
  - otherwise: `405 Method Not Allowed` and `Allow: GET, POST`.
- `path: "/subscribe"` → closure requiring `"GET"`; otherwise `405` and `Allow: GET`.
- unmatched paths receive Gerbil’s built-in 404 handler (`mux/static.ss:70-82`).

The Datastar example demonstrates string method checks, `405`, `Allow`, `204`, static path registration, server startup and `!NoTimeout`:

- `datastar-gerbil/example.ss:81-124`
- `datastar-gerbil/example.ss:128-154`

Gerbil handlers must invoke exactly one response method before returning:

- `gerbil/src/std/net/http/server/interface.ss:35-70`

## 2. Initial HTML

The official Datastar v1.0.2 browser bundle is:

```html
<script type="module"
  src="https://cdn.jsdelivr.net/gh/starfederation/datastar@v1.0.2/bundles/datastar.js"></script>
```

Official documentation recommends self-hosting for production:

- <https://data-star.dev/docs.md>, **Installation**
- Current package example: `datastar-gerbil/example.ss:71-79`

A minimal page can contain:

```html
<body data-init="@get('/subscribe')">
  <pre id="state">…escaped initial state…</pre>
  <!-- input controls invoke @post('/') -->
</body>
```

`data-init` executes when loaded and can execute again if the attribute is patched or modified. Avoid placing it inside the repeatedly morphed `<pre>`:

- <https://data-star.dev/docs.md>, **`data-init`**
- Datastar CQRS example: **CQRS**, using `data-init="@get(...)"` and `data-on:click="@post(...)"`.

For a terminal that must remain subscribed in a hidden tab:

```html
data-init="@get('/subscribe', {openWhenHidden: true})"
```

Official defaults close a `GET` stream while the page is hidden and reopen it when visible; `openWhenHidden` defaults to `false` for GET:

- <https://data-star.dev/docs.md>, **Backend Actions / `@get()` / Options**

The initial navigation should use raw `ResponseHandler-write!` with `text/html; charset=utf-8`, as the example does at `example.ss:81-99`. `response/datastar-elements` is available but is primarily a Datastar action patch response and emits exact `Content-Type: text/html`:

- `datastar-gerbil/http/api.ss:89-119`
- `datastar-gerbil/http/private/core.ss:301-333`

The package provides no page template or HTML escaping helper. State inserted into `<pre>` must be escaped at least for `&`, `<`, and `>`.

## 3. Long-lived `/subscribe` response

`call-with-datastar-sse` validates the Gerbil request/response and delegates to `call-with-sse`; it otherwise ignores the request:

- `datastar-gerbil/http/api.ss:163-168`

`call-with-sse`:

- calls `ResponseHandler-begin!` once with status 200;
- emits `Content-Type: text/event-stream`;
- emits `Cache-Control: no-cache`;
- keeps the response open for the callback’s dynamic extent;
- closes the writer normally when the callback returns;
- invalidates the session in cleanup.

Evidence: `sse-gerbil/sse.ss:19-38`.

Gerbil adds chunked transfer framing and `Connection: close`; it may automatically gzip or deflate if requested:

- `gerbil/src/std/net/http/server/request.ss:67-75`
- `gerbil/src/std/net/http/server/request.ss:143-183`
- Wire tests: `datastar-gerbil/http/httpd-test.ss:208-260`, `sse-gerbil/sse-test.ss:305-363`

The server must use `response-timeout: !NoTimeout`. Its default output timeout is 120 seconds and is installed before handler execution:

- `gerbil/src/std/net/http/server/interface.ss:82-109`
- `gerbil/src/std/net/http/server/server.ss:230-246`
- `datastar-gerbil/README.md:31`
- `datastar-gerbil/example.ss:138-147`

### Exact fat morph

For a full server-rendered morph of one element, send:

```scheme
(patch-elements session "<pre id=\"state\">…escaped state…</pre>")
```

Exact minimal event:

```text
event: datastar-patch-elements
data: elements <pre id="state">…escaped state…</pre>

```

The blank line is required. With default `outer` mode, Datastar matches the top-level element by ID and morphs it. This is the recommended “fat morph” behavior:

- <https://data-star.dev/docs.md>, **In Morph We Trust**
- <https://data-star.dev/docs.md>, **SSE Events / `datastar-patch-elements`**

An explicit target is also supported:

```scheme
(patch-elements session html selector: "#state")
```

which adds:

```text
data: selector #state
```

Do not use `mode: 'replace` unless literal node replacement rather than morphing is required. The library supports both; `outer` is the default and official recommendation:

- `datastar-gerbil/http/private/core.ss:284-293`
- `datastar-gerbil/http/private/core.ss:423-494`
- Exact framing tests: `datastar-gerbil/http/private/core-test.ss:491-562`
- Mode validation: `core-test.ss:563-585,717-724`

Relevant exact event/options implemented by the package:

| API option | SSE output |
|---|---|
| `selector:` | `data: selector …` |
| `mode:` | `data: mode outer|inner|replace|…` |
| `namespace:` | `data: namespace html|svg|mathml` |
| `use-view-transitions?:` | `data: useViewTransition true` |
| `view-transition-selector:` | `data: viewTransitionSelector …` |
| `event-id:` | `id: …` |
| `retry-duration:` | `retry: …`; omitted when absent or 1000 ms |

Implementation: `core.ss:387-417,423-494`. The exact event name is `datastar-patch-elements`.

## 4. Tuna subscription versus another broadcaster

Tuna already provides the required multi-subscriber broadcaster.

`command-runtime-subscribe-state!` atomically returns the current revision, value and a new subscription. Each subscription owns a capacity-one channel and is registered under the runtime lock:

- `tuna/tuna/lib/runtime.ss:312-328`

On a changed transition, Tuna installs the new immutable root and performs nonblocking `channel-try-put` to every active subscription:

- `tuna/tuna/lib/runtime.ss:132-153`

Thus:

- **One browser:** one Tuna subscription.
- **Multiple browsers:** one Tuna subscription per SSE handler; no second broadcaster.
- A slow reader receives one coalesced wakeup and must reread the latest snapshot; it does not block the command owner.
- Fanout work is still O(number of subscribers) under the runtime mutex.
- `state-subscription-close!` removes and closes a subscription idempotently: `runtime.ss:336-348`.
- Tuna shutdown closes all remaining subscription channels after draining accepted commands: `runtime.ss:216-227,350-362`.

The SSE handler should retain the atomic initial snapshot returned during subscription, send it, wait for invalidation, call `command-runtime-snapshot`, and send the newly rendered `<pre>`. EOF from `state-subscription-wait!` means runtime shutdown. Cleanup must close the subscription in `finally`.

The separate broadcaster in `datastar-gerbil/example.ss:12-53` exists because that example owns ad hoc mutable counter state; Tuna applications should use Tuna’s state subscriptions instead.

## 5. Disconnects, backpressure and lifecycle

### Disconnect detection — high risk

There is no proactive disconnect notification. A closed browser is discovered by a later write/flush or server shutdown:

- `datastar-gerbil/README.md:31`
- `sse-gerbil/sse.ss:40-58`

A handler blocked solely in `state-subscription-wait!` can therefore remain alive after the browser disconnects. The current Tuna wait API has no timeout parameter (`runtime.ss:330-334`), and Datastar Gerbil exports no heartbeat helper.

Available application-level alternatives:

1. Periodically perform a full `<pre>` patch even without changes.
2. Import `:gerbil-sse/sse` directly and send a raw SSE comment heartbeat.
3. Poll `state-subscription-try-wait!` and combine it with an application timer, accepting bounded update latency.
4. Build an application-level wait/timer multiplexing seam.

### Backpressure — medium risk

`sse-send!` writes and flushes synchronously under a per-session mutex. Concurrent sends cannot interleave, but a slow client blocks that connection’s handler:

- `sse-gerbil/sse.ss:40-58`
- concurrency test: `sse-gerbil/sse-test.ss:226-278`

With `!NoTimeout`, that block can be unbounded. Prefer one writer loop per session and bounded/coalesced Tuna invalidations. Each accepted connection owns a Gerbil handler thread, and the default maximum is 1024:

- `gerbil/src/std/net/http/server/server.ss:150-165`
- `gerbil/src/std/net/http/server/interface.ss:95-108`

Server stop closes listener and client sockets, waits up to three seconds, then terminates remaining threads:

- `server.ss:114-138`

Stopping Tuna first closes state subscriptions and gives handlers a clean opportunity to return before stopping HTTP.

### Error behavior

A transport failure is latched in the SSE session and re-raised; normal close is skipped:

- `sse-gerbil/sse.ss:28-38,40-58`
- `sse-gerbil/sse-test.ss:191-224`

After SSE headers are committed, an HTTP error response cannot safely replace the stream. Gerbil logs handler exceptions and attempts a 500, but the response handler rejects acting twice; outer cleanup then closes the socket:

- `gerbil/src/std/net/http/server/server.ss:233-260`
- `gerbil/src/std/net/http/server/request.ss:77-86`

The subscription therefore requires unconditional `finally` cleanup.

## 6. Safe `POST /` submission and empty CQRS response

Datastar’s default `@post('/')` sends all non-private signals as a JSON body with `Datastar-Request: true`. Relevant options include `payload`, `filterSignals`, `requestCancellation`, and retry policy:

- <https://data-star.dev/docs.md>, **`@post()` / Options**
- `204` is explicitly excluded from retry under the `'always'` retry mode.

`read-signals`:

- accepts POST, PUT and PATCH JSON bodies;
- reads only when `Content-Length` or `Transfer-Encoding` is advertised;
- limits bodies to 1 MiB;
- strictly parses JSON;
- consumes the body once;
- does not validate `Content-Type`.

Evidence:

- `datastar-gerbil/http/api.ss:18-73`
- `datastar-gerbil/http/private/request.ss:54-73`
- TCP tests: `datastar-gerbil/http/httpd-test.ss:43-70,158-206`

`datastar-request?` recognizes only a case-insensitive `Datastar-Request: true` value:

- `datastar-gerbil/http/api.ss:75-77`
- `datastar-gerbil/http/private/request.ss:75-86`

Safe boundary requirements:

1. Require method POST and, if desired, `datastar-request?`.
2. Parse once with `read-signals`.
3. Validate allowed fields, sizes and types.
4. Construct an application-owned immutable Tuna request. Never accept a client-selected action/transition symbol.
5. Submit a fixed interned transition name and proper argument list with `command-runtime-submit-transition!`.
6. Do not mutate submitted lists or contained mutable objects after admission; Tuna transfers payload ownership by reference.
7. Return `204 No Content` only for `accepted`.

Tuna admission is nonblocking and returns exactly `accepted`, `full`, or `not-running`:

- `tuna/tuna/lib/runtime.ss:265-306`
- `tuna/tuna/README.md:96-121`

`full` and `not-running` must not be silently reported as success. Their HTTP status/retry mapping remains an application decision, commonly a retryable 503 or explicit conflict/shutdown response.

Two materially different acknowledgment semantics remain:

- **Admission acknowledgment:** return 204 immediately after `accepted`. Lowest latency and clean CQRS separation, but transition failures are stored only in the completion and need a waiter/logger if they must be observed.
- **Completion acknowledgment:** wait with `command-completion-wait!`, then return 204. Detects command failure but keeps the POST connection open and couples command latency to the response.

Tuna catches per-command exceptions into completions and continues its worker:

- `runtime.ss:173-196`

Current `tuna/main.ss` is not directly usable for this stateful web loop: it constructs a lexical, stateless `make-command-runtime` and exposes neither the runtime nor HTTP integration:

- `tuna/tuna/main.ss:11-29`

An owning application entry point is therefore required; Datastar Gerbil contains no Tuna adapter.

## 7. Current capabilities versus missing helpers

### Present

- Strict signal decoding and `Datastar-Request` predicate.
- One-shot element, signal and script responses.
- Long-lived SSE response lifetime.
- Correct Datastar element/signal/script event construction.
- Outer morph, replace and all documented patch modes.
- Serialized, flushed SSE sends with failure latching.
- Tuna atomic snapshots, coalesced per-client subscriptions and nonblocking fanout.

Public façade: `datastar-gerbil/http.ss:1-11`; implementation: `http/api.ss:8-245`.

### Missing

- Method-aware router.
- HTML/page templating and escaping.
- Tuna request schema/adapter and command-status HTTP mapping.
- Heartbeat or timed subscription wait helper.
- Immediate disconnect/cancellation signal.
- Authentication, authorization, Cross-Site Request Forgery protection or origin checks.
- Post-commit completion/error logging.
- Coordinated Tuna/HTTP lifecycle wrapper.
- Proxy buffering headers/configuration.

## 8. Blocker: installed Gerbil chunk terminator

**Blocker:** the installed Gerbil dev31 emits `0\r\n` rather than the required `0\r\n\r\n` when a chunked response closes. The official Datastar conformance runner failed every tested completed SSE response with:

```text
http: unexpected EOF reading trailer
```

Gerbil commit `4531c21b` fixes this by adding the final newline:

- `gerbil/src/std/net/http/common/chunked.ss:102-116`
- Commit: <https://git.cons.io/mighty-gerbils/gerbil/commit/4531c21b90fa6ee04f374af905ae3ddb9d89d590>
- Pull request: <https://git.cons.io/mighty-gerbils/gerbil/pulls/1476>

The Datastar manifest still records dev31:

- `datastar-gerbil/manifest.ss:1-5`

Local Datastar tests pass because their raw parser stops at a zero-size chunk without consuming the required trailer terminator:

- `datastar-gerbil/http/test-support/listener.ss:139-152,169-188`

Do not claim interoperable completed SSE responses until running against `4531c21b` or later.

## 9. Supported build and validation commands

Package metadata:

- `datastar-gerbil/gerbil.pkg:1-2` depends on `git.cons.io/jay/gerbil-sse`.
- `datastar-gerbil/build.ss:1-5` builds the four public/private modules, not the example or tests.
- `datastar-gerbil/README.md:15-39` documents:

```sh
cd datastar-gerbil
gerbil pkg install git.cons.io/jay/gerbil-sse
gerbil build
gerbil test -v 0 ./...
gerbil test -v 0 -D datastar-conformance ./http/conformance-test.ss
gerbil env gxi ./example.ss
```

Focused checks:

```sh
(cd sse-gerbil && gerbil test -v 0 ./sse-test.ss)
(cd tuna/tuna && ./test/run-command-runtime-matrix.sh)
(cd gerbil && gerbil test src/std/net/http/common/chunked-test.ss)
```

`gerbil build` was not run because this research role was read-only and build output would modify `.gerbil/`.

## 10. Unresolved decisions

- Whether hidden tabs keep `/subscribe` open (`openWhenHidden: true`) or reconnect on visibility.
- Admission acknowledgment versus completion acknowledgment for POST.
- HTTP mapping and retry policy for `full`, `not-running`, invalid payloads and command failures.
- Browser input JSON schema and fixed Tuna transition name.
- Heartbeat interval and acceptable update latency/backpressure timeout.
- CDN versus self-hosted `datastar.js` and Content Security Policy.
- Escaping/serialization format for the state `<pre>`.
- Maximum supported subscriber count and shutdown ordering.

## Repository state note

The inspected `datastar-gerbil` checkout has unstaged modifications in all implementation/test files except metadata/README; findings describe the current working tree. No staged files were present. The research did not modify source or tests.