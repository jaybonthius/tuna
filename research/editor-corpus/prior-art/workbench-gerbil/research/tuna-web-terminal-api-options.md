# Tuna browser-terminal minimal vertical-slice API options

## Recommendation

Use an **independent `tuna-web-terminal` application/example package** around Tuna. It owns one state command runtime, one immutable application root, the browser adapter, application input normalization, two application transitions, HTTP routing, rendering, and lifecycle. Tuna core and the existing `tuna` executable remain unchanged.

The minimal coherent shape remains:

- one process-wide `make-state-command-runtime` and root shared by every tab;
- root-owned ordered keymaps, pending sequence, and replaceable input-normalization policy;
- a fixed global keymap with unmodified logical `i` bound to one counter-increment transition;
- stock Datastar `data-on:keydown__document__capture__prevent` invoking one small custom `@terminalKey()` action;
- a module-owned per-page FIFO with at most one `fetch("/")` awaiting an admission response;
- no retry, sequence identifier, server reorder buffer, or client-side Tuna semantics;
- self-hosted, versioned Datastar and plugin modules at separate asset routes;
- `GET /` for the page, `POST /` for admission, and `GET /subscribe` for the sole user-visible result stream;
- one Tuna state subscription per Server-Sent Events (SSE) connection and a complete outer morph of `#state` for every observed revision;
- no second broadcaster, heartbeat, persistence, authentication, rendering framework, or Tuna runtime modification.

This is a Command Query Responsibility Segregation (CQRS) boundary: `POST /` acknowledges only Tuna admission with `204`; `/subscribe` renders authoritative committed state. The custom FIFO is transport ordering, not Datastar or Tuna semantic state.

The remaining browser protocol design is now settled: the browser and HTTP handler preserve bounded raw keyboard facts, while the fixed application dispatcher normalizes them from the authoritative dequeue-time root. Unknown valid key names are input, not transport errors.

One deployment prerequisite remains: the source checkout is Gerbil `4531c21b`, which contains chunked-terminator fix #1476, but the active `gxi` observed during research was `/opt/gerbil/v0.19-dev-31-g4a4d1a30`, which predates it. Acceptance must run with an active Gerbil built from `4531c21b` or a descendant. Do not patch around the defect or modify the Gerbil checkout.

## Materially different shapes

### Host placement

| Shape | Benefit | Cost | Assessment |
|---|---|---|---|
| Extend `tuna/main.ss` | One executable and existing startup flags | Makes a host-neutral executable own browser, HTTP, Datastar, rendering, and application-root policy | Reject |
| Add web modules/executable to `:tuna` | Small physical footprint | Couples Tuna's normal build/distribution to web dependencies and application policy | Reject |
| Independent package, analogous to `tuna/packages/dummy` | Preserves Tuna's boundary and independently owns dependencies/lifecycle | Adds one small package and executable | **Recommended** |

The independent package may live alongside Tuna examples/packages, but it must have its own package identity and build entry point. Its intended public surface is its executable. Normalizer, policy constructors, renderer, root, and handler procedures remain package-internal.

### POST transport ordering

| Shape | Ordering | Failure semantics | Cost | Assessment |
|---|---|---|---|---|
| Stock `@post` | Default cancellation loses earlier requests; disabled cancellation permits concurrency and reorder | Datastar v1.0.2 has a documented/source retry discrepancy | Lowest | Prototype only |
| Custom FIFO action | Preserves one tab's delivered event order through Tuna admission | No-retry delivery can lose an event but cannot invert admitted events | Small | **Recommended** |
| Client sequence plus server reorder/deduplication | Can detect/reorder and support controlled retry | Requires identity, mutable buffers, duplicate/gap/expiry/reconnect policy | Large | Defer |

The FIFO proof remains narrow: document listener invocations append in browser delivery order; request `n+1` is not sent until request `n` has produced a response or transport failure; a `204` is emitted only after request `n` enters Tuna's FIFO lane. Cross-tab requests race and are globally ordered by actual Tuna admission.

### Browser asset distribution

| Shape | Benefit | Cost | Assessment |
|---|---|---|---|
| Separate pinned Datastar ESM and plugin ESM | Follows Datastar's public `action()` extension model | Two module assets plus an import map | **Recommended** |
| One application-built Datastar/plugin bundle | One script and pinned unit | Couples the host to a custom frontend build and obscures upstream artifact | Unnecessary |
| CDN Datastar plus local plugin | Minimal repository asset | External availability/integrity dependency and version drift | Reject for this slice |

Use versioned routes such as `/assets/datastar-v1.0.2.js` and `/assets/tuna-terminal-v1.js`. Record the upstream Datastar commit/checksum with the vendored asset and map the plugin's `datastar` import to that exact module.

## Authoritative application model

An illustrative root and raw request are:

```scheme
(defstruct TerminalRoot
  (counter input-policy ordered-maps pending-sequence)
  final: #t
  equal: #t)

(defstruct TerminalKeydownRequest
  (version type key code location repeat is-composing
           alt-key ctrl-key meta-key shift-key)
  final: #t
  equal: #t)
```

`TerminalKeydownRequest` is an immutable-by-contract application value containing the exact validated envelope, not a `KeyStroke`. Its three strings are defensively copied before admission; neither the parsed JSON object nor caller-owned mutable string storage is retained. The type should be opaque outside the package, and no accessor should expose mutable backing strings without copying.

The initial root contains:

- `counter = 0`;
- the default normalization policy below;
- `ordered-maps = (list global-map)`;
- `pending-sequence = (empty-key-sequence)`.

The fixed `global-map` contains one entry:

```scheme
(make-key-stroke 'logical #\i '())
  -> (make-transition-key-binding 'terminal-increment '())
```

All root descendants are immutable by contract. Application constructors defensively copy caller-owned table spines, entries, and strings and never publish mutable aliases. There is no second root, per-tab state cell, browser state mirror, or process-global keymap/policy cell outside Tuna's live root.

## Smallest root-owned normalization policy

### Recommended data shape

Use a fixed package-internal application function over a small, data-only root value:

```scheme
(defstruct TerminalInputPolicy
  (identity-source
   single-scalar-as-character?
   identity-map
   modifier-map)
  final: #t
  equal: #t)
```

The fields have these closed application meanings:

- `identity-source` is either the application constant `'logical-key` or `'physical-code`. It chooses both the raw source field and resulting Tuna domain: `key`/`'logical` or `code`/`'physical`.
- `single-scalar-as-character?` enables a fallback from an unmapped selected string containing exactly one Unicode scalar value to that character.
- `identity-map` is an immutable exact-string table. A value is either a controlled Tuna key code (symbol, character, or exact integer) or the private `input-ignored` sentinel.
- `modifier-map` has exactly four application-known slots corresponding to `altKey`, `ctrlKey`, `metaKey`, and `shiftKey`. Each value is a canonical Tuna modifier symbol or `#f` to omit that flag.

The policy constructor validates its closed selectors and modifier outputs, validates controlled code types without consulting live bindings, defensively copies every table/string, and retains no caller-owned mutable alias. Raw table keys are compared as strings and are never interned. The normalizer collects modifier outputs as a set before passing them in Tuna's canonical order, so two browser flags may intentionally alias one canonical modifier without producing duplicate constructor input.

This is the narrowest useful shape because it supports:

1. logical versus physical selection without changing the wire protocol;
2. replaceable exact named-key and physical-code mappings;
3. replaceable modifier aliases;
4. default character handling without enumerating every Unicode character;
5. explicit policy-level ignoring without embedding procedures in state or keymaps.

It deliberately does not add predicates, callbacks, procedure slots, regular expressions, per-binding normalizers, or a generic rule language. `location` and `repeat` remain available in the raw request, but the minimal policy does not branch on them. If later behavior genuinely needs those facts, the application can version this private policy shape rather than prebuilding a rule engine.

### Fixed function, replaceable data

The normalizer should be one fixed, pure application procedure conceptually shaped as:

```scheme
(normalize-terminal-keydown input-policy raw-request)
  -> KeyStroke | input-ignored | input-unrecognized
```

It is **not** a Tuna-core function and is **not** stored in the root or a keymap. Users replace policy data through ordinary authoritative state transitions. The dispatcher always reads the policy from the root current when Tuna's owner dequeues the raw request, so a policy replacement admitted earlier can change how an already queued later keyboard request resolves.

The algorithm is:

1. Select `request.key` for `'logical-key` or `request.code` for `'physical-code`.
2. Look up the selected raw string in `identity-map`.
3. If the table returns `input-ignored`, return that outcome.
4. If it returns a controlled code, use that code.
5. Otherwise, if scalar fallback is enabled and the string is exactly one Unicode scalar value, use that character.
6. Otherwise return `input-unrecognized`.
7. Map each true browser modifier flag through the four policy slots, omit `#f`, deduplicate, put the result in canonical Tuna order, and call public `make-key-stroke` with the selected domain and controlled code.

Exact table lookup precedes scalar fallback, allowing a replacement policy to remap or ignore even a one-character string. The fixed function never calls `string->symbol`, never chooses a transition, and never consults a keymap.

### Default policy data

The default policy is:

```scheme
identity-source:             'logical-key
single-scalar-as-character?: #t
modifier-map:                ((alt . meta)
                              (ctrl . control)
                              (meta . super)
                              (shift . shift))
```

Its application-owned `identity-map` maps these named strings to existing controlled source symbols:

| Raw `key` | Controlled logical code |
|---|---|
| `Enter` | `'enter` |
| `Escape` | `'escape` |
| `Backspace` | `'backspace` |
| `Tab` | `'tab` |
| `Delete` | `'delete` |
| `Insert` | `'insert` |
| `Home` | `'home` |
| `End` | `'end` |
| `PageUp` | `'page-up` |
| `PageDown` | `'page-down` |
| `ArrowUp` | `'up` |
| `ArrowDown` | `'down` |
| `ArrowLeft` | `'left` |
| `ArrowRight` | `'right` |

The default table also maps the settled standalone modifier/lock names to `input-ignored` as defensive application policy. This is replaceable root data, not a transport whitelist. The plugin already suppresses normal browser delivery of those events.

`Dead`, `Unidentified`, function keys, media keys, and any other bounded multi-character value are valid transport input. They become `input-unrecognized` under the default policy unless the authoritative root maps them. A future physical policy can select `'physical-code`, disable scalar fallback, and map bounded values such as `KeyI` to application-controlled physical codes without changing HTTP or Tuna core.

## Dispatcher and Tuna boundary

The package defines two host transitions:

- `terminal-dispatch(root, TerminalKeydownRequest)` normalizes from `root.input-policy`, then applies the approved prefix/resolution algorithm against the same dequeue-time root.
- `terminal-increment(root)` returns `state-changed` with `counter + 1` while preserving input policy, maps, and pending state.

Dispatcher outcomes are:

- **stroke:** append it to `root.pending-sequence`, resolve through dequeue-time `root.ordered-maps`, and apply the approved exact/continuation/undefined/absent behavior;
- **unrecognized:** do not construct a stroke or invoke a target; use the application's terminal unbound-input path, clearing an existing prefix and applying any root-owned feedback policy;
- **ignored:** do not invoke a target and leave the pending prefix and root unchanged.

For the minimal root, an unrecognized request with no pending prefix is `state-unchanged`; with a pending prefix it changes only by clearing that prefix. No extra feedback field or rule language is needed for this slice.

Exact resolution still clears the prefix in the base, invokes the selected live transition directly with `invoke-state-transition` on the same owner call stack, and propagates the target outcome as specified by the approved Tuna input-keymap contract. It never submits nested runtime work. This yields at most one installation/revision for one admitted request.

The HTTP boundary admits only the fixed dispatcher name and passes the raw immutable request:

```scheme
(command-runtime-submit-transition!
 runtime
 'terminal-dispatch
 (list raw-keydown-request))
```

No request field may select a Tuna domain, normalized code, canonical modifier, transition, command, binding, keymap, mode, prefix, or root. Domain selection and every mapping are authoritative application state.

## Keyboard JSON protocol

### Wire envelope

The plugin snapshots browser facts synchronously into this exact version-1 shape:

```json
{
  "version": 1,
  "type": "keydown",
  "key": "i",
  "code": "KeyI",
  "location": 0,
  "repeat": false,
  "isComposing": false,
  "altKey": false,
  "ctrlKey": false,
  "metaKey": false,
  "shiftKey": false
}
```

Validation requires an object with exactly those fields:

- `version` is exact integer `1`;
- `type` is exactly `"keydown"`;
- `key` is a string of 1 through 64 Unicode scalar values;
- `code` is a string of 0 through 64 Unicode scalar values;
- `location` is an exact integer from 0 through 3;
- the remaining six fields are JSON booleans;
- `isComposing` must be `false`.

The public `read-signals` body ceiling remains 1 MiB. Exceeding the body ceiling or either field bound is a size/schema failure. Legacy `keyCode`, DOM targets, timestamps, normalized domains/codes/modifiers, commands, bindings, and Tuna state are forbidden.

After these checks, the handler copies the raw fields into `TerminalKeydownRequest` and submits it unchanged. It must not:

- interpret `key` or `code` names;
- choose logical versus physical identity;
- map modifier booleans;
- construct a `KeyStroke`;
- intern request strings;
- consult the root or current policy;
- reject a bounded string merely because current application policy does not recognize it.

Version/schema/type/size validation is transport validation; `isComposing: true` is the one explicit protocol rejection. Unknown bounded names, including direct standalone-modifier names, pass the HTTP boundary. The plugin normally suppresses standalone modifiers before POST, while current root policy decides the outcome of any direct valid payload.

`repeat` means each delivered repeat keydown is an ordinary additional raw request. `code` and `location` are preserved even under the default logical policy so later authoritative policy replacement does not require a wire change.

### Plugin filtering

The action ignores a delivered keydown whose `key` is one of the settled browser modifier/lock names:

`Alt`, `AltGraph`, `CapsLock`, `Control`, `Fn`, `FnLock`, `Hyper`, `Meta`, `NumLock`, `ScrollLock`, `Shift`, `Super`, `Symbol`, or `SymbolLock`.

It also ignores `isComposing: true`. Stock `__prevent` has already synchronously called `preventDefault()` when the event is cancelable, but no POST is queued. Supporting committed composed text requires a future input protocol; keydown alone is insufficient.

The plugin performs no other key interpretation. It snapshots values before asynchronous work and never retains the mutable `KeyboardEvent` as queue payload.

## FIFO action contract

The stable document uses:

```html
data-on:keydown__document__capture__prevent="@terminalKey()"
```

The public Datastar extension is only `action({name: "terminalKey", apply(ctx) {...}})` and `ctx.evt`. The action has no listener of its own and relies on stock `data-on` for document targeting, capture, synchronous cancellation, and morph cleanup.

One loaded plugin module owns one queue and pump for that page:

1. Require a `keydown` `KeyboardEvent`; optionally suppress a second call for the same event object.
2. Ignore a standalone modifier/lock keydown and any event with `isComposing === true`.
3. Snapshot the exact wire fields into an immutable plain object and append it.
4. If no request is active, `fetch("/", ...)` the head using `POST`, `Content-Type: application/json`, `Datastar-Request: true`, same-origin credentials, and the JSON body.
5. Do not send the next item until the current fetch settles. A `204` is the only successful admission acknowledgment.
6. Never retry automatically. On non-204 or network failure, log a transport error, discard that queue item, and continue pumping. A network failure is ambiguous, but later requests were not yet sent, so continuing cannot invert admitted order.
7. A fetch that never settles intentionally stalls the queue rather than adding abort/retry ambiguity. Page unload discards the in-memory queue.

This provides ordered at-most-once attempts, not exactly-once delivery. It contains no stream identifier, sequence counter, deduplication state, keymap knowledge, normalization table, or response morph logic.

## HTTP and admission protocol

Gerbil's static mux matches paths, not methods. The root closure branches on `Request-method`.

### Application endpoints

| Endpoint | Behavior |
|---|---|
| `GET /` | Snapshot current runtime state and return the HTML document |
| `POST /` | Validate/copy one raw keyboard envelope and attempt Tuna admission |
| `GET /subscribe` | Open one Datastar SSE stream backed by one Tuna state subscription |

Other methods return `405` with `Allow: GET, POST` for `/` and `Allow: GET` for `/subscribe`.

`POST /` requires `application/json` (parameters may be accepted) and `Datastar-Request: true`, then parses once with public `read-signals`. Its status mapping is:

| Condition | Status |
|---|---|
| Raw request accepted into Tuna, whether later normalized, ignored, or unrecognized | `204 No Content`, empty body |
| Runtime queue `full` | `503 Service Unavailable` |
| Runtime `not-running` | `503 Service Unavailable` |
| Malformed JSON/schema/type, body/field size violation, `isComposing: true`, or missing Datastar marker | `400 Bad Request` |
| Unsupported media type | `415 Unsupported Media Type` |

There is no `unsupported key` transport status. A valid unknown key is admitted to the fixed dispatcher and normally receives `204` before completion.

For `accepted`, immediately arrange a background waiter on the public `CommandCompletion`, then write `204` without awaiting it. A waiter thread per accepted command is bounded by the runtime's bounded outstanding work. It calls `command-completion-wait!`, catches transition exceptions, and emits a structured host log entry. Successful completion needs no browser response. A failed command leaves the prior root/revision installed, creates no SSE patch, and does not prevent later Tuna work.

### Asset routes

Register exact GET-only routes separately, for example:

- `GET /assets/datastar-v1.0.2.js`
- `GET /assets/tuna-terminal-v1.js`

They return pinned JavaScript modules with a JavaScript content type. Other methods return `405`; unmatched paths remain `404`. Versioned immutable cache headers are appropriate. Do not use an unrestricted directory route.

## Initial document and rendering

The body has exactly one application state element:

```html
<!doctype html>
<html lang="en"
  data-on:keydown__document__capture__prevent="@terminalKey()">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <script type="importmap">{"imports":{"datastar":"/assets/datastar-v1.0.2.js"}}</script>
  <script type="module" src="/assets/datastar-v1.0.2.js"></script>
  <script type="module" src="/assets/tuna-terminal-v1.js"></script>
</head>
<body data-init="@get('/subscribe', {openWhenHidden: true})">
  <pre id="state">(terminal (revision 0) (counter 0))</pre>
</body>
</html>
```

The scripts and attributes are transport wiring, not application UI. `data-init` remains outside `#state`, so a state morph cannot recreate its subscription owner. `openWhenHidden: true` keeps background tabs attached to the shared terminal.

The renderer projects only:

```scheme
(terminal (revision <revision>) (counter <counter>))
```

It does not enumerate opaque keymaps or expose normalization tables. Serialize deterministically, then escape text in this order: `&` to `&amp;`, `<` to `&lt;`, and `>` to `&gt;`. Insert only escaped text between static `<pre id="state">` tags.

## Subscription, morph, and disconnect behavior

Every `GET /subscribe` handler:

1. calls `command-runtime-subscribe-state!` and retains its atomic initial revision/root/subscription triple;
2. opens `call-with-datastar-sse`;
3. immediately sends the complete rendered `<pre id="state">...</pre>` with selector `#state` and outer mode;
4. waits with `state-subscription-wait!`;
5. after each wake, ignores the notification as state, rereads `command-runtime-snapshot`, and sends the latest complete element;
6. exits on end-of-file and always calls `state-subscription-close!` in `finally`.

Tuna's capacity-one invalidations deliberately coalesce. A slow tab may skip revisions but converges on the latest root. There is one SSE writer loop and one Tuna subscription per tab, with no application broadcaster.

The minimal slice adds no heartbeat. An idle disconnected tab may retain a blocked handler/subscription until the next state change or shutdown. The next patch discovers the broken connection and `finally` closes the subscription. Production connection accounting would reopen that out-of-scope decision.

## Multi-tab and prefix consequences

All tabs observe and mutate the same runtime/root:

- each tab serializes only its own delivered events;
- different tabs are globally ordered by Tuna admission, not browser timestamps;
- every changed revision invalidates every active subscription;
- hidden and visible tabs converge on the same latest counter;
- a slow tab can coalesce revisions without blocking Tuna's owner;
- normalization uses whichever policy is authoritative when the owner dequeues each raw request.

`pending-sequence` is shared. If multi-key bindings are added, tab A can begin a prefix and tab B can complete or clear it. An ignored raw event preserves that prefix; an unrecognized or keymap-absent event follows terminal unbound policy and clears it. Per-tab prefixes require tab identity and per-tab state inside the authoritative root and remain outside this slice.

## Startup and shutdown ownership

The application executable owns all resources.

Startup order is:

1. initialize logging;
2. construct default policy, fixed map, and initial immutable root;
3. construct and start the state command runtime;
4. construct the method-dispatching mux and HTTP server around that runtime;
5. start the server and wait in the host main thread.

The runtime must run before handlers can subscribe. The HTTP server uses `response-timeout: !NoTimeout` for long-lived SSE.

On host termination/unwind:

1. call `command-runtime-stop!`, rejecting new admissions and draining accepted work;
2. join the runtime; completion closes remaining subscription channels and lets SSE loops return;
3. stop the HTTP server, closing listener/connections and providing Gerbil's fallback for stuck handlers;
4. shut down logging.

During drain, `POST /` maps `not-running` to `503`. Runtime shutdown is a backstop for subscriptions, not a substitute for handler `finally` cleanup.

## Gerbil v19 staging prerequisite

Read-only verification on the original research run found:

```text
source checkout HEAD: 4531c21b90fa6ee04f374af905ae3ddb9d89d590
fix commit subject:    std/net/http: Fix chunked response terminator (#1476)
active gxi:            /opt/gerbil/bin/gxi
active version:        v0.19-dev-31-g4a4d1a30
```

Before claiming the vertical slice works, validation must establish that the `gxi`/`gerbil` actually executing the host was built from `4531c21b` or a descendant, and the Datastar conformance suite must run under that same active runtime. No application workaround, local Gerbil patch, or modified Gerbil checkout is acceptable.

## Behavior-facing acceptance seam

The highest public seam is the real host over HTTP plus a real browser, observing only public Tuna snapshots/subscriptions/completions and Datastar events. Acceptance should establish:

- `GET /` contains one `#state` pre with the exact escaped initial datum and only pinned local module URLs;
- a delivered non-modifier, non-composing keydown is synchronously default-prevented and emits the exact raw JSON envelope;
- standalone modifier and composing keydowns are prevented but issue no POST;
- direct `isComposing: true`, malformed, mistyped, extra-field, and over-bound payloads fail before Tuna admission;
- every bounded unknown `key`/`code` string is transport-admitted with `204` and is not interned or converted in the handler; an unmapped selected multi-character identity invokes no target and follows unrecognized-prefix behavior, while an unknown unused field does not affect current source selection;
- a direct valid standalone-modifier payload is admitted rather than rejected by transport and the default policy ignores it without disturbing root or prefix;
- mutation of parsed/caller-owned strings or policy-table inputs after construction cannot alter an admitted request or installed policy;
- the default policy maps single-scalar keys, the named-key table, and `ctrl/alt/meta/shift` to canonical `control/meta/super/shift` strokes;
- exact identity-table entries can remap or ignore a single-character key ahead of scalar fallback;
- replacing policy through authoritative state changes how a later queued raw request normalizes, including logical `key` versus physical `code` selection, without changing HTTP or keymaps;
- unrecognized and ignored outcomes never invoke a target; ignored preserves a prefix while unrecognized applies terminal unbound policy;
- a controlled server delaying each `204` observes at most one POST in flight and receives a rapid `i, i, i` burst in order;
- three admitted default-policy `i` events produce counter 3 and monotonically increasing revisions through `/subscribe`;
- two tabs receive complete outer morphs and converge on the same root;
- runtime `full`/`not-running` conditions map to the specified statuses without false `204`;
- `204` can precede a deliberately failing transition completion, whose failure is logged while the prior root/revision remains installed and later input succeeds;
- renderer metacharacters cannot escape the pre element;
- repeated morphs do not duplicate the document listener;
- stream disconnect and runtime shutdown close their Tuna subscriptions when detected;
- completed chunked SSE responses are wire-valid under active Gerbil `4531c21b` or later.

Focused pure tests beneath the host should exercise the policy constructor and fixed normalizer through application-visible outcomes, not private table backing. Public resolver/runtime tests remain useful, but private queue, struct backing, modifier encoding, or keymap-vector representation are not acceptance targets.

## Decision status

The prior named-key, modifier, and composition questions are settled:

- named strings are application-owned replaceable policy data, never a transport whitelist;
- default modifiers are `ctrlKey -> control`, `altKey -> meta`, `metaKey -> super`, and `shiftKey -> shift`;
- composing events are ignored by the plugin and rejected if posted directly;
- bounded unknown key/code strings are admitted raw and resolved by current root policy;
- the normalizer is a fixed application function over data-only root policy and a raw immutable request.

There is **no remaining owner decision for the minimal local vertical slice**. The design is ready to be converted into an implementation contract; this artifact is not that contract.

No Architecture Decision Record (ADR) is needed for the independent example package, private FIFO, or private data-only normalization shape. An ADR would be justified before moving HTTP/browser policy into Tuna core, storing executable normalization procedures in authoritative state, adding server reorder/deduplication state, introducing another state owner/broadcaster, or changing shared prefixes to per-tab semantics.

## Evidence basis

This recommendation is grounded in:

- `research/tuna-datastar-server-mechanics.md` — routing, SSE framing, admission, subscriptions, lifecycle, and Gerbil #1476;
- `research/datastar-keyboard-terminal-plugin.md` — document capture/prevent behavior, public `action()` API, stock fetch limitations, and raw browser wire facts;
- `research/tuna-web-terminal-runtime-integration.md` — independent host placement, immutable root, dispatcher, subscriptions, and multi-tab behavior;
- `plans/tuna-input-keymaps/spec.md` — approved resolver/dispatcher boundary, controlled external tokens, root/prefix authority, and public acceptance seam;
- current `tuna/tuna/lib/runtime.ss`, `lib/keymap.ss`, and `test/input-dispatch-test.ss` — public APIs and reference dispatcher behavior;
- current `datastar-gerbil/http/api.ss`, `example.ss`, and `sse-gerbil/sse.ss` — public request/SSE calls, the 1 MiB body ceiling, and response lifetime.
