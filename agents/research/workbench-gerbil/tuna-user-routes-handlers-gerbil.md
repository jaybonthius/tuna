# Tuna user/package HTTP routes and handlers — Gerbil v19 research

**Target:** `/home/jay/Code/workbench-gerbil/research/tuna-user-routes-handlers-gerbil.md`

## Conclusion

Tuna should use a **startup-snapshotted immutable route list with live, name-resolved handler bodies**:

- User/package configuration composes immutable exact-method/exact-path route descriptors before host construction.
- The host validates conflicts and compiles them with Tuna’s built-ins into Gerbil’s `new-static-mux`.
- Route membership is fixed for that host lifetime.
- Each request resolves the route’s interned handler symbol through Tuna’s live function cells exactly once, so later `defun` replacement affects new requests but not in-flight calls.
- HTTP handlers run on concurrent Gerbil connection threads. State changes must cross an opaque HTTP context into the existing bounded command runtime; only Tuna’s owner thread installs state.
- Keep this API in a dedicated `:tuna/lib/http` module, not the general prelude/runtime and not Datastar.
- The smallest safe initial handler contract is **finite, one-shot HTTP**: `(handler context request) -> immutable response value`. Keep raw `ResponseHandler`, streaming, Server-Sent Events (SSE), upgrades, and Datastar callbacks outside this initial public seam.

This is Emacs-like in the useful sense: configuration selects stable named routes, while function cells remain live. It avoids an import-order registry, mutable router locking, server restart, response double-action errors, and HTTP objects crossing the authoritative command owner.

Confidence: **high** for Gerbil/Tuna mechanics and the snapshot/live-body split; **medium** that finite one-shot handlers cover the immediate product need.

## Current behavior and constraints

### Tuna currently has no public route seam

- Tuna documents one serialized state runtime and “fixed private HTTP routes”: `tuna/tuna/README.md:3-8`.
- `make-tuna-http-mux` installs exactly five private paths using `new-static-mux`; method checks remain inside handlers: `tuna/tuna/private/http.ss:208-213,279-288,320-351`.
- The HTTP module exports only its mux, subscription runners, decoder, and page helper; it does not export route or response configuration: `tuna/tuna/private/http.ss:3-18`.
- `main` loads configuration before constructing the host, but passes only listener and command-capacity values: `tuna/tuna/main.ss:12-27`.
- Tuna’s prelude exports live definitions, runtime state outcomes, listener values, renderer, and profiler—but no HTTP route contract: `tuna/tuna/lib/prelude.ss:43-110`.

**Finding — blocker:** user/package HTTP routes cannot currently be installed without modifying private Tuna source.

### Configuration already provides the right registration window

- `load-config!` evaluates ordinary Gerbil forms sequentially, allowing configuration to import compiled packages and compose values before startup: `tuna/tuna/lib/config.ss:29-41`.
- Startup selects one optional/default/explicit config; it does not layer multiple files: `tuna/tuna/lib/startup.ss:15-31`.
- Existing startup values are snapshotted after config, while renderer/profiler definitions remain live: `tuna/tuna/main.ss:17-23`; `tuna/tuna/README.md:29-35`.
- Host construction already validates listener and initial rendering before worker, mux, observer, or listener resources: `tuna/tuna/private/host.ss:100-129`.

This supports route validation and snapshotting during `make-tuna-host`, before any server resource is started.

### The command owner must remain authoritative

- State installation explicitly rejects every thread except the command runtime owner: `tuna/tuna/private/runtime.ss:168-179`.
- Producers submit bounded work and receive `accepted`, `full`, or `not-running`: `tuna/tuna/private/runtime.ss:357-411`.
- Accepted transition failures are returned through completions without killing the worker: `tuna/tuna/private/runtime.ss:235-282`.
- Queue payloads remain caller-owned by reference until completion and must not be mutated: `tuna/tuna/private/runtime.ss:357-370`.
- The public runtime facade already exposes submission, completion waiting, and coherent snapshots without exposing state installation: `tuna/tuna/lib/runtime.ss:3-58`.
- Tuna explicitly keeps state/runtime application-neutral and gives it no HTTP behavior or cancellation engine: `tuna/tuna/README.md:277-284`.

**Finding — high:** a user handler must not invoke a transition and install its candidate on the HTTP thread. It must submit through the existing runtime.

### Gerbil v19 routing and concurrency

The inspected authoritative Gerbil checkout is `4531c21b90fa6ee04f374af905ae3ddb9d89d590`; `/opt/gerbil` reports `v0.19-dev-32-g4531c21b`.

- `Request` exposes URL, protocol, method string, headers, buffered body reader, peer address, and logger: `gerbil/src/std/net/http/server/interface.ss:11-20`.
- `RequestHandler` receives request and response and must perform exactly one response action: `gerbil/src/std/net/http/server/interface.ss:63-71`.
- `new-closure-handler` is the idiomatic adapter from a procedure to `RequestHandler`: `gerbil/src/std/net/http/server/handlers/closure.ss:8-19`.
- `new-static-mux` supports exact `path:` and recursive `rest:` rules. Rules are searched in declaration order; no match returns the standard 404 handler: `gerbil/src/std/net/http/server/mux/static.ss:21-54,57-82`.
- Matching uses raw `Request.url.path`; query is stored separately and the URL layer does no path normalization or percent-decoding: `gerbil/src/std/net/url.ss:17-32,127-133,160-179`.
- Gerbil accepts each connection on a separate handler thread, bounded by `max-connections`: `gerbil/src/std/net/http/server/server.ss:154-172`.
- One request is handled, then body, response, buffered I/O, and socket are closed: `gerbil/src/std/net/http/server/server.ss:219-279`.

The checked-in `:std/net/httpd` manual/tutorial still describe the removed older registration API and are not authoritative for v19: `gerbil/doc/reference/std/net/httpd.md:1-13`; `gerbil/doc/tutorials/httpd.md:33-65`.

## Recommended smallest public seam

Keep the exact names subject to normal API review, but the minimal shape is:

```scheme
;; :tuna/lib/http, imported explicitly
(make-tuna-http-route method path handler-name)
tuna-http-route?
tuna-http-routes                  ; live config value, snapshotted at host creation

;; Handler result
(make-tuna-http-response status content-type body
                         headers: ...)
tuna-http-response?

;; Opaque command-owner capability
(tuna-http-snapshot context)
(tuna-http-submit-transition! context name arguments)

;; Generic bounded HTTP body helper
(tuna-http-read-body request limit: ...)
```

Handler contract:

```scheme
(defun package-health (context request)
  (let-values (((revision state) (tuna-http-snapshot context)))
    (make-tuna-http-response
     OK
     "text/plain; charset=utf-8"
     (string-append "revision " (number->string revision) "\n"))))
```

Configuration composition:

```scheme
(import :tuna/lib/prelude
        :tuna/lib/http
        :my-package/http)

(set! (value tuna-http-routes)
      (list my-package-health-route
            my-package-update-route))
```

### Why a config value rather than `register-route!`

Packages should export route descriptors or lists; the user config should explicitly compose the authoritative list.

Advantages:

- no hidden import-time registration;
- no dependence on package import order;
- no global registry cleanup between tests or hosts;
- duplicate validation sees the complete set;
- route values naturally follow Tuna’s existing startup-snapshot model;
- application packages that do not expose HTTP need not import the HTTP module.

A convenience append function can be added later, but it should mutate only the pre-start configuration value, not a serving registry.

### Route representation and dispatch

A route contains:

1. canonical method string;
2. exact path string;
3. interned handler symbol.

At host construction:

1. validate and copy every route field;
2. reject conflicts;
3. verify the target is currently function-bound;
4. group routes by path;
5. create one closure handler per path;
6. dispatch method inside that closure;
7. pass the resulting exact path rules to `new-static-mux`.

This preserves Gerbil’s lock-free static lookup and permits:

- unknown path → 404;
- known path, unknown method → 405 plus aggregate `Allow`;
- same path with distinct methods → valid;
- same method/path twice → startup error.

Do not rely on Gerbil’s first-rule-wins behavior for duplicates.

### Handler and response contract

**Recommended initial contract:** `(context request) -> TunaHttpResponse`.

The adapter—not the package—performs the single `ResponseHandler-write!`. This is safer than exposing the raw response because:

- handler errors occur before response commitment and can become one controlled 500;
- invalid return values become controlled 500 responses;
- packages cannot accidentally call two response operations;
- the adapter can validate headers and body types centrally;
- peer-reset suppression can be limited to the adapter-owned wire write;
- handlers never retain a response or writer beyond request scope.

`TunaHttpResponse` should require:

- a Gerbil `Status`, using exported values such as `OK`, `Created`, or `Bad-Request`; authoritative statuses are in `gerbil/src/std/net/http/server/status.ss:32-80`;
- a mandatory content-type string;
- a string or byte-vector body, with strings encoded once as UTF-8;
- copied response headers.

Reject carriage return/line feed in names or values and reject user-supplied server-owned framing headers: `Connection`, `Content-Length`, `Transfer-Encoding`, and `Content-Encoding`. Gerbil writes header strings directly and performs no such injection check: `gerbil/src/std/net/http/common/ioutil.ss:169-180`.

Gerbil’s native `write!` requires a `Status`, header list, and byte vector: `gerbil/src/std/net/http/server/interface.ss:35-42`. It generates length/chunking/compression framing: `gerbil/src/std/net/http/server/request.ss:90-142`.

### Request-body API

Gerbil does **not** enforce a total body cap:

- fixed `Content-Length` creates a delimited reader of the advertised size;
- chunked input creates an open-ended chunk reader: `gerbil/src/std/net/http/server/request.ss:40-51`.

Datastar’s existing adapter demonstrates the correct pattern: stream into bounded chunks and reject once total data exceeds 1 MiB: `datastar-gerbil/http/api.ss:17-18,41-51`.

**Finding — high:** exposing raw body reads without a bounded helper makes user routes an easy memory/latency denial-of-service path, even on loopback.

The generic HTTP module should provide a bounded byte-reader independent of Datastar. Reusing 1 MiB as the initial default is evidence-backed by the current Datastar adapter; any different cap is a product policy decision.

## Registration, conflicts, and validation

### Registration timing and ownership

- Route list composition happens during ordinary sequential config loading.
- Host construction snapshots and validates it before service creation.
- The host owns that immutable snapshot and compiled mux.
- Mutating `tuna-http-routes` after host construction has no effect.
- Changing route membership requires constructing/restarting the Tuna process, not `Server.restart!`.

Gerbil’s `restart!` stops the server and replaces the whole configuration: `gerbil/src/std/net/http/server/interface.ss:129-132`; implementation at `gerbil/src/std/net/http/server/server.ss:62-68`. It would close active SSE connections and is disproportionate for route edits.

### Duplicate and reserved-path behavior

Recommended deterministic rules:

- Duplicate `(method, path)`: fatal startup/configuration error, even if handler names match.
- Same path with distinct methods: allowed.
- User route on a Tuna-reserved path: fatal regardless of method.
- Reserve:
  - `/`
  - `/subscribe`
  - `/profile/subscribe`
  - `/assets/` and existing asset paths
- No override/last-wins behavior in the first public version.
- Error diagnostics should include method, path, and both handler names.

Tuna’s existing built-ins occupy these paths at `tuna/tuna/private/http.ss:340-351`.

### Method validation

Use exact uppercase method strings. Validate RFC-style token characters, cap length, and reject at least `CONNECT` and `TRACE` in the initial local application server. Do not silently uppercase user input, because that can turn distinct definitions into hidden duplicates.

`HEAD` and `OPTIONS` should not be inferred automatically in the minimal seam:

- Gerbil does not infer them.
- Current Tuna explicitly returns 405 for unsupported methods: `tuna/tuna/private/http.ss:208-213,279-281,320-338`.
- Automatic `OPTIONS` would imply a Cross-Origin Resource Sharing (CORS) policy Tuna does not currently define.

### Path validation

Require an exact origin path that:

- starts with `/`;
- is nonempty and bounded by the server request-line limit;
- contains no query marker, fragment marker, whitespace, backslash, NUL, or control characters;
- has valid percent escapes if `%` is allowed;
- contains no `.` or `..` segments.

Document that matching is against the raw URL path; `/x`, `/x/`, and `/x%2F` are distinct.

Gerbil’s default request-line cap is 1024 and header cap is 32768: `gerbil/src/std/net/http/server/interface.ss:95-108`. The parser enforces the supplied byte budgets: `gerbil/src/std/net/http/common/ioutil.ss:67-72,100-126`.

## Command-owner context

The HTTP context should be an opaque capability, not `TunaService` and not a raw response object.

Minimum operations:

- coherent immutable-root snapshot;
- bounded named-transition submission.

Submission must preserve the existing runtime result contract:

- `accepted` with completion;
- `full`;
- `not-running`.

Handlers may wait for completion before constructing a response. A package exception then remains before response commitment and can be mapped to controlled 500 or caught by application code.

Rules:

- decode HTTP data on the HTTP thread;
- submit only bounded, immutable-by-contract values;
- never pass `Request`, `ResponseHandler`, streaming writers, or sockets through the command queue;
- never submit nested work from the command owner;
- map `full`/`not-running` to an explicit overload/shutdown response such as 503;
- client disconnect does not cancel already accepted work.

The runtime has no cancellation facility, and accepted work drains during stop: `tuna/tuna/private/runtime.ss:372-425,465-477`; `tuna/tuna/README.md:221-227`.

## Live redefinition

**Recommendation: yes, installed routes should follow live handler redefinition; route membership should not.**

Dispatch should perform:

```scheme
(let (handler (function-ref handler-name))
  (handler context request))
```

exactly once per request.

Consequences:

- a concurrent `defun` replacement yields a complete old or new body;
- an in-flight handler continues its captured old body;
- the next request sees the replacement;
- function aliases follow target replacement;
- removing the function or replacing it with incompatible arity yields a logged controlled 500, not stale execution;
- changing the route config value does not add/remove installed routes.

Tuna’s function registry publishes stable atom cells under a mutex and reads implementations lock-free: `tuna/tuna/lib/bindings.ss:69-149,345-367,417-422`. Saved `function-ref` procedures are documented snapshots: `tuna/tuna/README.md:446-460`. The renderer already applies the same resolve-once-per-invocation pattern: `tuna/tuna/private/render.ss:67-82`.

## Exceptions and peer disconnects

### Finite public handlers

The route adapter should:

1. invoke the named handler;
2. validate its response value;
3. on handler/validation failure, emit one sanitized Tuna error record and substitute a generic 500 response;
4. call `ResponseHandler-write!` exactly once;
5. contain only `EPIPE`/`ECONNRESET` arising from that adapter-owned write;
6. propagate other I/O errors.

Do not blanket-catch peer-shaped exceptions around application execution. Tuna’s current SSE implementation uses a private marker to distinguish send-proven peer loss from renderer failures: `tuna/tuna/private/http.ss:215-277`. Tests specifically prove renderer-raised `EPIPE`/`ECONNRESET` remain application failures: `tuna/tuna/test/server-runtime-test.ss:205-229`.

Gerbil also suppresses `EPIPE`/`ECONNRESET` only during server-owned response finalization: `gerbil/src/std/net/http/server/server.ss:201-212`.

### Current observability gap

Gerbil normally logs handler errors and attempts an empty 500: `gerbil/src/std/net/http/server/server.ss:249-265`. Tuna’s configured request sink deliberately drops every record: `tuna/tuna/private/host.ss:29-48`.

**Finding — high:** merely allowing Gerbil to catch user handler exceptions would make those failures effectively silent in Tuna. The public adapter needs its own sanitized error record or Tuna’s request-log ownership must be changed.

### Streaming and Datastar

Do not include arbitrary streaming in the smallest public route seam.

Current Tuna SSE behavior is carefully phase-sensitive:

- send-proven peer loss is marked and contained;
- renderer errors propagate;
- subscription cleanup always occurs: `tuna/tuna/private/http.ss:223-318`.
- SSE owns the writer for the callback’s dynamic extent and flushes each send: `sse-gerbil/sse.ss:19-58`.
- Datastar exposes response writers and SSE callbacks directly: `datastar-gerbil/http/api.ss:85-125`.

A raw user handler contract would inherit all of these lifecycle obligations. It should be a separate advanced API only if there is a concrete need.

## Lifecycle

Current ordering is sound for snapshotted user routes:

1. load config;
2. snapshot/validate listener, root, renderer, transition, and routes;
3. start service/runtime;
4. construct static mux and start HTTP server;
5. wait on Tuna runtime;
6. close ingress and stop runtime;
7. join accepted commands and close subscriptions;
8. stop HTTP server;
9. stop completion observer;
10. stop logging.

Evidence: `tuna/tuna/main.ss:12-33`; `tuna/tuna/private/host.ss:137-205`; `tuna/tuna/private/service.ss:85-101,155-178`.

No route-specific init/shutdown hooks are needed initially. Compiled package module initialization already runs during config import. User handlers that create external resources must own them through their package/application lifecycle rather than the route descriptor.

Gerbil server stop closes all active sockets and forcibly terminates handlers remaining after roughly three seconds: `gerbil/src/std/net/http/server/server.ss:115-142`.

## Security and bounds

1. **Trusted code:** configuration evaluates arbitrary Gerbil and imports arbitrary compiled packages; this API is not a sandbox: `tuna/tuna/lib/config.ss:29-41`.
2. **Loopback only:** Tuna validates an IPv4 `127/8` listener and port 1–65535: `tuna/tuna/private/host.ss:84-109`. This prevents remote binding, not malicious local processes.
3. **Cross-site requests:** state-changing handlers need an explicit Origin/token/Datastar-marker policy. Loopback is not Cross-Site Request Forgery (CSRF) protection.
4. **Command queue:** default capacity is 256: `tuna/tuna/main.ss:10-23`; handlers must handle overload.
5. **Connections:** Gerbil defaults to 1024 concurrent connections: `gerbil/src/std/net/http/server/interface.ss:95-108`.
6. **Timeout:** Tuna sets global response timeout to `!NoTimeout` for SSE: `tuna/tuna/private/host.ss:168-175`. Finite user handlers must bound body reads, completion waits, and external I/O themselves.
7. **Bodies:** Gerbil has no total request-body cap; use the public bounded helper.
8. **Headers:** validate response headers against carriage-return/line-feed injection and reserve framing headers.
9. **Routes:** impose explicit method/path lengths and a finite route-count cap. The exact count is a product limit; 256 would align with Tuna’s current bounded-command scale but is not source-mandated.
10. **State:** snapshots expose the application root by reference. The immutable-root contract remains mandatory: `tuna/tuna/README.md:277-280`.
11. **No cancellation:** accepted state work may complete after the HTTP peer disconnects.

## Materially different options

### A. Startup snapshot + live named finite handler — **recommended**

- Exact method/path descriptors.
- Static mux.
- Name resolved once per request.
- Response value returned.
- Opaque command-owner context.

Smallest safe seam; deterministic conflicts; no router lock; safe response ownership.

### B. Startup snapshot + raw `(context request response)` handler

Reuses Gerbil directly and supports Datastar/SSE immediately, but exposes exactly-once response obligations, header injection, writer lifetime, peer-disconnect provenance, and streaming cleanup. Appropriate only as a separately named advanced seam.

### C. Mutable custom mux or copy-on-write registry

Allows runtime add/remove. Requires synchronized lookup/publication, deterministic concurrent duplicate semantics, lifecycle policy, and subscriber behavior during route removal. Gerbil’s built-in static mux does not provide registration. Not justified for minimal Emacs-like redefinition because live handler cells already provide useful runtime editing.

### D. Rebuild mux through `Server.restart!`

Simple conceptually, but restart closes every request/SSE connection and restarts listeners. It also conflicts with Tuna’s one-shot service/host lifecycle. Reject.

### E. gxhttpd-style module factories/servlet reload

The v19 tool loads configured modules and optional initialization procedures into a mutable dynamic mux: `gerbil/src/tools/gxhttpd/server.ss:18-70`. Its contract naming is inconsistent with its config comment: `gerbil/src/tools/gxhttpd/config.ss:14-21`. It is a standalone site-hosting implementation, not the minimal embedded Tuna API, and does not preserve Tuna live function-cell semantics.

## Residual gaps and risks

- **High:** no current public route API or tests exist.
- **High:** current request logging drops handler errors; user exceptions need explicit observability.
- **High:** arbitrary raw streaming cannot safely share the finite response contract.
- **Medium:** one-shot response values do not directly support Datastar’s current response-writing API. A separate Datastar response builder or advanced raw route would be needed.
- **Medium:** no cancellation exists for accepted commands after peer disconnect.
- **Medium:** Tuna’s global no-timeout server means package handlers can occupy connections indefinitely.
- **Medium:** exact allowed method set, request cap, route cap, and CSRF policy remain product/security choices.
- **Low:** live handler removal or wrong-arity redefinition will intentionally produce a controlled 500 rather than retain stale code.
- **Low:** raw URL paths are not normalized or decoded; this must be documented and tested.

## Evidence-backed validation commands

No build or tests were run during this read-only investigation.

### Focused Tuna validation after implementation

```sh
cd /home/jay/Code/workbench-gerbil/tuna/tuna

GERBIL_PATH="$PWD/.gerbil" GERBIL_LOADPATH= gerbil build

GERBIL_PATH="$PWD/.gerbil" GERBIL_LOADPATH= \
  timeout --signal=TERM --kill-after=10s 5m \
  gerbil test -v 0 \
    ./test/http-route-test.ss \
    ./test/server-runtime-test.ss \
    ./test/server-protocol-test.ss
```

Focused tests should cover validation/conflicts, 404/405/Allow, reserved paths, bounded bodies, content types/header rejection, overload, owner-thread installation, live old/new generation behavior, controlled 500 logging, peer resets, and stop/rebind.

Gerbil documents passing files/directories and recursive `/...` discovery at `gerbil/doc/reference/dev/test.md:1-25`.

### Full Tuna gates

```sh
cd /home/jay/Code/workbench-gerbil/tuna
make test

cd /home/jay/Code/workbench-gerbil
tuna/tuna/test/run-server-runtime-validation.sh
```

`make test` builds Tuna and package tests with the isolated development `GERBIL_PATH`: `tuna/Makefile:27-34`. The server validation script runs build, bounded recursive tests, compiler-isolation matrix, executable checks, and deterministic web-asset validation: `tuna/tuna/test/run-server-runtime-validation.sh:12-55`.

### Gerbil interface regression gate, only if Gerbil itself changes

```sh
cd /home/jay/Code/workbench-gerbil/gerbil

./build.sh env gerbil test \
  src/std/net/http/http-test.ss \
  src/std/net/http/server/server-test.ss

make check
```

Gerbil’s native HTTP tests demonstrate static mux, closure, one-shot, and chunked handlers at `gerbil/src/std/net/http/http-test.ss:14-65`. The documented full standard-library gate is `make check`: `gerbil/CONTRIBUTING.md:182-189`.