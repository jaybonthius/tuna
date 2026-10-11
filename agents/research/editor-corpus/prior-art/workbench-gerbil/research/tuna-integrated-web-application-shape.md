# Integrated Tuna web application shape

## Recommendation

Incorporate the web application into the existing `:tuna` package and existing `tuna` executable. Do not create `tuna-web-terminal`, a second executable, or a route-registration API.

The clean internal boundary is:

```text
Tuna application model
        ↓
state runtime/service
        ↓
private HTTP/Datastar adapter
        ↓
Gerbil HTTP server
```

HTTP and browser concerns must not flow back into the root, transitions, keymaps, renderer contract, or core runtime.

This supersedes only the **package/executable placement** in the prior web research, which recommended an independent package at `research/tuna-web-terminal-runtime-integration.md:3-17` and `research/tuna-web-terminal-api-options.md:3-36`. Its root, runtime, subscription, asset, rendering, and lifecycle findings remain applicable.

## Current behavior and constraints

| Severity | Finding |
|---|---|
| High | `tuna/main.ss` currently constructs a stateless `make-command-runtime`, not an authoritative state runtime, and exposes no HTTP application: `tuna/tuna/main.ss:11-29`. |
| High | The Oracle-approved but owner-pending web contract explicitly requires a separate package and unchanged executable, so it conflicts with this task and cannot be implemented unchanged: `plans/tuna-web-terminal/spec.md:1-16`. |
| Medium | `tuna/tuna/gerbil.pkg:1` has no Datastar dependency, and `tuna/tuna/build.ss:4-14` builds only existing libraries plus the `tuna` executable. |
| Medium | Active `/opt/gerbil` is dev31 (`4a4d1a30`), while completed Server-Sent Events (SSE) validation requires Gerbil `4531c21b` or later; the source checkout has the fix but the executing tools do not. |
| Medium | The inspected `datastar-gerbil` working tree is dirty, so commit `a0d020c` alone does not identify the effective dependency source. |
| Informational | Tuna, Datastar, SSE, and the outer repository have no staged files. Tuna itself is clean at `46783db`. |

The existing command runtime already provides the required single-owner state machinery:

- State runtime construction and immutable initial root: `tuna/tuna/lib/runtime.ss:69-87`.
- Atomic snapshots: `runtime.ss:124-130`.
- Owner-only installation, revision increment, and nonblocking subscriber invalidation: `runtime.ss:132-153`.
- Live transition resolution and one final installation: `runtime.ss:155-171`.
- Bounded admission statuses: `runtime.ss:265-306`.
- Atomic subscription plus initial snapshot: `runtime.ss:312-328`.
- Idempotent subscription cleanup: `runtime.ss:330-348`.
- Drain-and-close shutdown: `runtime.ss:350-382`.

The application-shaped dispatcher is already demonstrated at `tuna/tuna/test/input-dispatch-test.ss:59-102`: it resolves from the dequeue-time root, invokes a live transition directly, and propagates one final outcome without nested submission.

## Exact internal module ownership

These are proposed modules inside `/home/jay/Code/workbench-gerbil/tuna/tuna`; they remain under package identity `:tuna`.

| Module | Ownership |
|---|---|
| `lib/application/model.ss` | Private authoritative root, raw browser request, normalization policy, initial root construction, fixed keymap, dispatcher, and target transitions. Imports Tuna runtime/keymap APIs only; never HTTP or Datastar. |
| `lib/application/render.ss` | The single deliberate live view seam, `tuna-render-state`. Imports the model and Tuna prelude, but no HTTP types. |
| `lib/application/service.ss` | Owns exactly one state command runtime, ingress gate, bounded completion observer, and internal snapshot/admit/subscribe operations. It is the only module allowed to retain the runtime reference. |
| `lib/web/config.ss` | Defines startup configuration values and resolves them once into a validated immutable internal configuration. |
| `lib/web/private/assets.generated.ss` | Embedded immutable bytes for the pinned Datastar module and Tuna browser plugin. No runtime filesystem lookup. |
| `lib/web/http.ss` | Private Gerbil HTTP/Datastar adapter: fixed mux, method checks, JSON validation, ordinary responses, SSE loop, page shell, and exact asset handlers. |
| `lib/web/host.ss` | Composes application service plus HTTP server and owns coordinated start, wait, and shutdown. |
| `main.ss` | Logging, config selection/loading, configuration resolution, one host construction, lifecycle and final cleanup only. |

### Dependency direction

```text
bindings/runtime/keymap/prelude
              ↓
    application/model
       ↙             ↘
application/render  application/service
       ↘             ↙
         web/http ← web/assets
              ↑
          web/host ← web/config
              ↑
            main
```

Prohibited reverse dependencies:

- Model or renderer importing Gerbil HTTP, Datastar, request/response types, routes, or assets.
- HTTP handlers retaining or mutating a second application root.
- Renderer receiving a request, response, route, session, or server object.
- Browser assets containing Tuna transitions, keymaps, prefixes, or authoritative state.
- A second broadcaster beside Tuna state subscriptions.

Gerbil module exports are not enforceably package-private. “Private” therefore means unadvertised, absent from `:tuna/lib/prelude`, and subject to change. This is a convention rather than a language-enforced boundary.

## Authoritative root and runtime

Retain the prior private root shape:

```scheme
(defstruct TunaApplicationRoot
  (counter input-policy ordered-maps pending-sequence)
  final: #t
  equal: #t)
```

The exact name is internal; its ownership matters more than its spelling.

`lib/application/model.ss` constructs the initial root after configuration has loaded. `lib/application/service.ss` then passes it exactly once to:

```scheme
(make-state-command-runtime 256 initial-root)
```

There must be:

- one root installed only in that runtime;
- one runtime shared by all tabs;
- no global mirror of counter, policy, keymaps, or pending prefix;
- one Tuna state subscription per SSE connection;
- no Datastar/example-style subscriber list.

This follows Tuna’s documented application ownership at `tuna/tuna/README.md:128-178` and avoids duplicating the broadcaster already supplied by `runtime.ss:132-153,312-348`.

The shared root means a future multi-key prefix is also shared across tabs. Per-tab prefixes would require identity and per-tab state inside the one root; it is not an HTTP-session side table.

## Live renderer

Define the renderer with Tuna’s existing `defun`, not `defaction`:

```scheme
(defun tuna-render-state (revision root)
  ...)
```

`defun` caches the stable live cell but dereferences its current implementation on every call, so compiled callers observe configuration replacement: `tuna/tuna/lib/prelude.ss:61-106`. Raw live replacement mechanics are at `tuna/tuna/lib/bindings.ss:345-367,412-422`.

The HTTP adapter must call the wrapper for every initial page render and every SSE update. It must not capture `(function-ref 'tuna-render-state)` during host construction, because that would freeze a snapshot of the implementation.

Recommended renderer boundary:

- input: revision plus immutable application root;
- output: complete semantic `#state` fragment as a string;
- no request, response, session, route, or server arguments;
- adapter checks the result is a string;
- fixed page shell, subscription owner, scripts and asset URLs remain adapter-owned.

If exposing the private root representation to configuration is undesirable, a materially safer alternative is to pass a deterministic application view datum instead. That narrows coupling but makes the view-datum schema the renderer API. Do not solve this by passing HTTP context.

`defaction` is inappropriate here because its host-invocation metadata exists for mapping opaque host context into command arguments: `prelude.ss:113-187`; `bindings.ss:369-393,424-452`.

## Private fixed routes and HTTP adapter

Keep the fixed prior infrastructure endpoints as implementation details:

- `GET /` — page shell plus current authoritative snapshot.
- `POST /` — validate/copy one raw browser event and submit the fixed dispatcher transition.
- `GET /subscribe` — one Tuna subscription and one Datastar SSE loop.
- `GET /assets/datastar-v1.0.2.js`.
- `GET /assets/tuna-terminal-v1.js`.

Do not export:

- `register-route!`;
- route descriptors;
- handler registries;
- mutable mux access;
- config-supplied paths or handlers;
- request/response objects through Tuna actions.

Gerbil’s static mux is path-oriented, so private closures must enforce methods themselves. The Datastar example demonstrates this pattern at `datastar-gerbil/example.ss:81-124,128-147`.

The adapter should use only supported public Datastar calls:

- `read-signals` and `datastar-request?`: `datastar-gerbil/http/api.ss:61-77`;
- `call-with-datastar-sse`: `http/api.ss:163-168`;
- `patch-elements`: `http/api.ss:170-203`.

`read-signals` bounds request bodies to 1 MiB at `http/api.ss:18,44-73`. Ordinary page, asset, error, and `204` responses should use Gerbil’s `ResponseHandler-write!`; Datastar one-shot patch helpers are unnecessary.

Each subscription handler must:

1. acquire the atomic `(revision, root, subscription)`;
2. begin SSE;
3. immediately render and outer-patch complete `#state`;
4. wait for an invalidation;
5. reread the latest snapshot rather than treating the wakeup as state;
6. exit on EOF;
7. close the subscription in `finally`.

This is supported by `runtime.ss:312-348` and tested for coalescing/race-free registration at `tuna/tuna/test/state-runtime-test.ss:196-292`.

SSE transport begins status 200 with `text/event-stream` and `no-cache`, serializes writes and flushes each frame: `sse-gerbil/sse.ss:19-58`.

## Browser assets

Place browser sources and generated artifacts inside the existing Tuna package tree, not another Gerbil package:

```text
tuna/tuna/
  frontend/
    src/tuna-terminal-v1.ts
    ...
  assets/
    source/datastar-v1.0.2.js
    generated/tuna-terminal-v1.js
    SHA256SUMS
  lib/web/private/assets.generated.ss
```

Recommended distribution remains compiled embedding:

- official Datastar v1.0.2 bytes are pinned and checksummed;
- the plugin imports public `action` from `"datastar"`;
- both exact outputs are encoded into a private Gerbil bytevector module;
- asset handlers serve those constants;
- installed execution is independent of current directory.

Prior provenance and embedding evidence is at `research/tuna-web-terminal-build-browser-validation.md:245-350`. An installed data-directory alternative is materially valid but would require a new relocation/data-root contract that Tuna does not have.

## Package and build changes implied

The existing package identity and executable remain:

```scheme
(package: tuna prelude: :tuna/lib/prelude
 depend: ("git.cons.io/jay/gerbil-datastar"))
```

Datastar already declares SSE as its dependency at `datastar-gerbil/gerbil.pkg:1-2`, so Tuna should not directly depend on or import SSE unless it later needs raw heartbeat frames.

`tuna/tuna/build.ss` should compile the application modules before web modules, then continue to produce only:

```scheme
(exe: "main" bin: "tuna")
```

No second package metadata or executable is warranted.

The existing hard-coded runtime matrix module list at `tuna/tuna/test/run-command-runtime-matrix.sh:44-68` must be extended for the new modules and tests; otherwise normal and optimized compiled validation will silently omit the web application.

## Smallest configuration surface

### Recommended values

Use two ordinary global Tuna live values:

```scheme
(defvar tuna-listen-host
  "127.0.0.1"
  doc: "IPv4 address used by Tuna's local HTTP listener.")

(defvar tuna-listen-port
  8000
  doc: "TCP port used by Tuna's local HTTP listener.")
```

A user configuration overrides them through the established convention:

```scheme
(import :tuna/lib/prelude)

(set! (value tuna-listen-host) "127.0.0.1")
(set! (value tuna-listen-port) 9000)
```

This matches the README’s existing configuration example at `tuna/tuna/README.md:21-40`. `defvar` initializes only an unbound value, while later `set! (value ...)` replaces it; re-running `defvar` does not overwrite an assigned value: `tuna/tuna/lib/bindings.ss:608-619,635-670`.

Do not add `--host`, `--port`, environment-variable address overrides, or a generic server-options table yet. Tuna’s CLI currently selects exactly one configuration source and rejects all other argument shapes: `tuna/tuna/lib/startup.ss:15-31`.

### Validation

After the selected configuration has fully evaluated, but before constructing any root, runtime, observer thread, mux or server:

1. Snapshot both values.
2. Require host to be a nonempty string and a valid IPv4 literal.
3. Require port to be an exact integer in `1..65535`.
4. Defensively copy the host string.
5. Build and parse `inet4:<host>:<port>` with Gerbil’s public address parser.
6. Store the resulting address and copied display values in one immutable private startup configuration.

Gerbil’s parser validates the IPv4 host and port at `gerbil/src/std/net/address/parser.ss:185-200,237-261`. `ServerConfig.listen` accepts addresses and the server also parses canonical strings at `gerbil/src/std/net/http/server/interface.ss:82-108` and `server.ss:92-105`.

Port zero should remain a private test-constructor option rather than a user configuration value because Gerbil’s public server interface cannot report the selected ephemeral port: `interface.ss:111-133`.

### Precedence

The deterministic precedence is:

1. Compiled defaults: `127.0.0.1`, `8000`.
2. Exactly one selected configuration file:
   - no arguments: optional XDG default;
   - `--config FILE`: explicit file replaces the default selection;
   - `--no-config`: no file, therefore compiled defaults.
3. Within that file, sequential evaluation means the last assignment wins.
4. No address-specific CLI or environment layer.

The XDG/config selection rules are implemented at `startup.ss:6-31` and documented at `README.md:58-77`. Configuration evaluates one form at a time at `tuna/tuna/lib/config.ss:29-41`.

Startup settings are snapshotted. Mutating `tuna-listen-host` or `tuna-listen-port` after server construction must not silently restart or rebind the listener. By contrast, `tuna-render-state` remains live because it is called through its wrapper.

### Material alternative

A single `tuna-listen-address = "inet4:127.0.0.1:8000"` value has fewer fields, but it leaks Gerbil’s canonical address syntax into user configuration, makes a simple port override awkward, and implicitly opens DNS, IPv6 and Unix-socket policy. Two typed values are the smaller coherent user interface.

## Existing executable composition

`main.ss` should become sequential, avoiding construction of the current stateless runtime before configuration:

1. Initialize logging.
2. Select config path.
3. Load the selected config.
4. Resolve and validate listen configuration.
5. Construct the private initial root.
6. Construct one state command runtime with capacity 256.
7. Construct/start the bounded completion observer.
8. Start the runtime.
9. Construct/start the HTTP server with `response-timeout: !NoTimeout`.
10. Log `http://127.0.0.1:8000/` or the configured address.
11. Wait using the existing runtime wait behavior.
12. On unwind:
    - close ingress and stop runtime under the admission mutex;
    - join runtime;
    - synchronously stop HTTP;
    - close and drain the completion observer;
    - emit final lifecycle logging;
    - shut down logging.

The precise observer ordering and `C + 1` capacity argument are supported at `research/tuna-web-terminal-lifecycle-details.md:5-15,34-73,99-147`. Gerbil exposes no `server.wait!`; `stop!` is synchronous and has a three-second forced termination fallback: `gerbil/src/std/net/http/server/interface.ss:111-133`, `server.ss:114-138`.

The current logger exports only `log.info`: `tuna/tuna/lib/log.ss:14-21`. The integrated application should extend this same Tuna logger’s exports for structured completion/server errors rather than introduce a second package logger.

## Future extension seams left open

The design preserves these seams without committing to route registration:

- Live pure renderer replacement through existing `defun`.
- Live transition replacement through `deftransition` and `invoke-state-transition`.
- Root-owned keymap and input-policy replacement through ordinary transitions.
- Persistence by loading an initial root before `make-state-command-runtime` and subscribing to committed snapshots.
- Private host construction accepting capacity/address for tests.
- Future heartbeat/timed-wait support inside the private HTTP adapter.
- A future route/application API after real non-infrastructure endpoints establish requirements.
- Future IPv6/DNS/nonlocal listener policy by replacing the private configuration resolver.

It intentionally does not promise:

- public root representation;
- request/response handler registration;
- arbitrary paths;
- middleware;
- multiple runtimes;
- per-tab roots;
- browser-selected transition names;
- another state broadcaster.

## Risks and unresolved gaps

- **Blocker:** active Gerbil dev31 predates the completed chunk terminator fix. Completed SSE acceptance must use binaries built from `4531c21b` or later.
- **High:** the existing approved web contract has the wrong package/executable shape for this task and must not be implemented verbatim.
- **High:** nonloopback overrides require explicit origin, Cross-Site Request Forgery, authentication, transport security and Content Security Policy decisions.
- **Medium:** private Gerbil modules are private only by convention.
- **Medium:** no current startup/config tests cover listener values or precedence.
- **Medium:** idle SSE disconnects are detected only by a later write or server shutdown; Datastar documents the heartbeat gap at `datastar-gerbil/README.md:25-31`.
- **Medium:** the inspected Datastar checkout is dirty, so validation needs an accepted, reproducible dependency baseline.
- **Medium:** unconditional document-level keyboard prevention affects Input Method Editors, accessibility and browser shortcuts.
- **Low:** `Keymap` is intentionally opaque, so the renderer cannot enumerate it; any displayed map metadata must be retained separately by the application.

**Confidence:** high for package placement, dependency direction, state/runtime ownership, configuration precedence, and supported Gerbil/Tuna/Datastar APIs; medium for exact future module names and renderer argument shape because those modules do not yet exist.

## Validation commands

No build or test was run during this read-only investigation.

### Focused Tuna foundation

```sh
cd /home/jay/Code/workbench-gerbil/tuna/tuna
test/run-command-runtime-matrix.sh
```

Before integrated acceptance, its hard-coded compiled module/test list must include all new application/web modules and behavior suites.

### Full staged validation

Run with a Gerbil toolchain whose active embedded commit is `4531c21b` or a descendant, one fresh `GERBIL_PATH`, and empty `GERBIL_LOADPATH`:

```sh
cd /home/jay/Code/workbench-gerbil/sse-gerbil
gerbil build
gerbil test -v 0 ./sse-test.ss

cd /home/jay/Code/workbench-gerbil/datastar-gerbil
gerbil build
gerbil test -v 0 ./...
gerbil test -v 0 -D datastar-conformance ./http/conformance-test.ss

cd /home/jay/Code/workbench-gerbil/tuna/tuna
gerbil build
test/run-command-runtime-matrix.sh
```

Full integrated acceptance should additionally verify:

- the staged `tuna` executable starts at `127.0.0.1:8000`;
- config and `--no-config` precedence;
- invalid host/port fail before resources start;
- exact embedded asset hashes;
- initial page and completed SSE framing;
- live renderer replacement;
- one root shared by multiple browser tabs;
- runtime overload/shutdown mappings;
- subscription and observer cleanup;
- Chromium, Firefox and WebKit browser behavior.