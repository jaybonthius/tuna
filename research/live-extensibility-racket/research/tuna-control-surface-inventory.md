# Tuna control-surface inventory

## Scope and result

**Result:** Tuna already has strong live replacement for named callables, values, and the whole application renderer. It does **not** have comparable composition or lifecycle ownership for commands, HTTP routes, page fragments, independent publications, logging, or host extensions. The browser-facing application remains a fixed keydown pipeline around one startup-selected transition.

This inventory treats current source and accepted Architecture Decision Records (ADRs) as authoritative. Historical editor research is used only to identify unresolved package needs. Tuna’s intended boundary remains an opaque-state runtime; packages, not core, define state shapes, commands, input semantics, renderers, and editor concepts (`AGENTS.md:33-49`; `docs/tuna/research/working-model.md:5-17,72-86`).

Severity here measures redesign pressure:

- **Blocker:** prevents independently installed packages from supplying the behavior without replacing core behavior.
- **High:** permits replacement but not safe composition, ownership, or later redefinition.
- **Medium:** externally fixed policy that may constrain a clean-break design.

## Current production flow

1. `main` initializes logging, selects and evaluates configuration, snapshots listener, initial state, and transition name, constructs the private host, starts it, waits, and then performs host-before-logging cleanup (`tuna-racket/packages/tuna/main.rkt:37-95`).
2. The host validates loopback listener, renderer, and selected transition before allocating runtime resources. It constructs one command runtime, one always-present profiler coordinator, and one completion-observer service (`tuna-racket/packages/tuna/private/host.rkt:87-168`).
3. HTTP accepts only a fixed route table. POST `/` strictly decodes one keydown message and submits the host’s captured transition name (`tuna-racket/packages/tuna/private/http.rkt:446-585`).
4. A bounded service reserves observation capacity before runtime admission. One runtime owner resolves the named live transition at dequeue time, applies it to the current root, and publishes a new revision only for `state-changed` (`tuna-racket/packages/tuna/private/completion-observer.rkt:468-570`; `tuna-racket/packages/tuna/private/runtime.rkt:646-778`).
5. State subscriptions coalesce invalidations and reread the latest root. Each render captures the current live renderer once; Datastar outer-replaces `#state` (`tuna-racket/packages/tuna/private/runtime.rkt:435-572`; `tuna-racket/packages/tuna/private/http.rkt:417-434`; `tuna-racket/packages/tuna/private/datastar-sse.rkt:28-36`).

## Control-surface inventory

### 1. Live bindings and definitions

**Current mechanism**

- Callable and value names occupy separate stable registries, so the same symbol can name both. Each stable cell publishes one complete generation; aliases follow cell identity and reject cycles (`tuna-racket/packages/tuna/bindings.rkt:54-123,414-465`).
- Callable generations distinguish function, action, transition, alias, and unbound states. Actions atomically bundle implementation, host descriptor, argument acquirer, and documentation (`tuna-racket/packages/tuna/bindings.rkt:56-63,178-209`).
- Definition-site wrappers reread their cell on every invocation, while `function-ref` captures one implementation snapshot (`tuna-racket/packages/tuna/bindings.rkt:211-231`; `tuna-racket/packages/tuna/prelude.rkt:105-120`).
- Values support aliases, logical removal, dynamic bindings, explicit inherited contexts, automatically local values, and hide/reveal of global values (`tuna-racket/packages/tuna/bindings.rkt:624-824`).
- Repeating `define-value!` preserves an already bound value while updating documentation and locality metadata, whereas callable definitions replace the complete generation (`tuna-racket/packages/tuna/bindings.rkt:536-577`).
- Descriptors are detached snapshots with copied documentation (`tuna-racket/packages/tuna/bindings.rkt:125-176,510-534`).

**Current policy**

- Names must be interned symbols.
- There is no multi-name transaction. Ordinary mutable values and callable argument data remain caller-owned (`tuna-racket/README.md:63-64`; `tuna-racket/docs/adr/0002-live-registry-and-owner-runtime-lifecycle.md:13-19`).
- Public syntax fixes function/action/transition/value categories and restricted formal syntax (`tuna-racket/packages/tuna/prelude.rkt:125-275`).

**Missing live replacement/composition — High**

- No registry enumeration, definition-change notification, ownership token, provenance, or generation handle is public.
- No named before/after/around contribution survives later redefinition. Replacement erases the previous generation; removal cannot distinguish an old owner from a newer definition.
- No atomic activation across several names, routes, page contributions, and resources.
- Captured procedures and direct procedure event listeners intentionally remain old implementations.

**Plausible package needs**

Named commands, settings, renderer helpers, package-local values, and context-local policy already fit. Independently replaceable packages may additionally need owned multi-contribution composition, introspection, stale-cleanup protection, and a way to react to redefinition without taking permanent ownership of the underlying name.

### 2. Commands, actions, transitions, and events

**Current mechanism**

- Public action invocation supports explicit argument lists or one coherent host-context acquisition step (`tuna-racket/packages/tuna/bindings.rkt:268-303`).
- Transitions are named live functions receiving current opaque state plus arguments (`tuna-racket/packages/tuna/bindings.rkt:305-327`).
- State transitions must return `state-changed` or `state-unchanged`; each carries a public command result, while only `state-changed` carries a replacement root (`tuna-racket/packages/tuna/private/outcome.rkt:3-29`).
- Runtime requests retain the name and resolve the current generation after dequeue, enabling queued work to see later redefinition (`tuna-racket/packages/tuna/private/runtime.rkt:287-356,646-669`).
- Public events provide ordered listeners, stable listener IDs, live lookup for symbol listeners, captured direct procedures, snapshot dispatch, and explicit removal (`tuna-racket/packages/tuna/event.rkt:20-81`).

**Current policy**

- Runtime exposes three submission modes: action arguments, action context, and state transition.
- Nested submission by the owner thread is forbidden (`tuna-racket/packages/tuna/private/runtime.rkt:287-320`).
- Listener failure stops event dispatch and propagates; listener return values are ignored (`tuna-racket/packages/tuna/event.rkt:69-81`).
- Production core publishes no command, publication, delivery, host-start, or host-stop event. Non-test uses of `tuna/event` are absent (`docs/tuna/profiler-extraction-research.md:330-344`).

**Missing live replacement/composition — Blocker**

- Browser ingress can invoke only the startup-selected transition; public actions and arbitrary runtime submissions have no HTTP dispatch bridge.
- No public callback surrounds decode, reservation, admission, dequeue, execution, completion, and failure.
- There is no command registry enumeration, interactive metadata, command-loop middleware, or composable advisory observation.
- Existing events have no owner/resource lifecycle, automatic cleanup, or failure containment suitable for host infrastructure.

**Plausible package needs**

Packages can define transitions and actions now. Different applications plausibly need package-owned browser-message decoding, command selection, argument acquisition, command metadata, and advisory observation without replacing the selected transition or changing authoritative results.

### 3. Browser bindings and fixed keydown policy

**Current mechanism**

- `tuna/application` exposes an immutable keydown request with eleven fields and checked accessors (`tuna-racket/packages/tuna/application.rkt:6-22,24-112`).
- The public constructor accepts version 1, `"keydown"`, arbitrary string key/code fields, location 0–3, and booleans (`tuna-racket/packages/tuna/application.rkt:55-91`).
- HTTP adds stricter policy: exactly eleven JSON properties, bounded key/code lengths, no unknown or duplicate fields, and composing input is rejected (`tuna-racket/packages/tuna/private/http.rkt:56-108,123-279`).
- The bundled JavaScript installs a document-capture keydown handler through fixed page attributes and POST behavior (`tuna-racket/packages/tuna/private/http.rkt:343-365`).

**Current policy**

- Core owns a DOM-keyboard-shaped request vocabulary and rejects Input Method Editor (IME) composition.
- Marker, media type, and body validation have fixed precedence; accepted work receives 204 only after observer registration, not after command success (`tuna-racket/packages/tuna/private/http.rkt:471-502`).

**Missing live replacement/composition — Blocker**

- No package can replace or add message types, schemas, normalization, stale-event addressing, focus context, pointer input, accessibility commands, paste, or IME handling.
- The public constructor is broader than HTTP, but the transport remains fixed.
- Current research explicitly says keydown-only behavior is insufficient evidence for a usable editor baseline (`docs/tuna/research/research-gaps.md:446-456`).

**Plausible package needs**

Input packages may need to own semantic normalization and state-target addressing while core retains only generic bounded decoding/admission mechanics. Focus, command-target scope, and stale browser-event behavior remain unresolved research questions (`docs/tuna/research/research-gaps.md:129-157`).

### 4. Command runtime

**Current mechanism**

- Public constructors expose stateless and state-owning runtimes, bounded submission, completions, snapshots, subscriptions, and lifecycle (`tuna-racket/packages/tuna/runtime.rkt:33-60`).
- One ordinary Racket owner thread executes a bounded first-in, first-out queue. Admission returns only `accepted`, `full`, or `not-running` (`tuna-racket/packages/tuna/private/runtime.rkt:143-224,267-344`).
- Completions are single-assignment, helper-thread-free, and re-raise the exact arbitrary failure value (`tuna-racket/packages/tuna/private/runtime.rkt:47-55,106-141`).
- Ordinary application failure affects only its request; owner infrastructure failure fails current and queued work with the original reason and closes subscriptions (`tuna-racket/packages/tuna/private/runtime.rkt:738-815`).
- Stop closes ingress, drains accepted work, then closes subscriptions; join reports an `uncaught-owner` wrapper for infrastructure failure (`tuna-racket/packages/tuna/private/runtime.rkt:226-265,622-637`).

**Current policy**

- Capacity is fixed at construction and must be a positive fixnum.
- The launcher hard-codes capacity 256 (`tuna-racket/packages/tuna/main.rkt:12,76-78`).
- Mutable roots are immutable only by caller contract, not transitively frozen (`tuna-racket/docs/adr/0002-live-registry-and-owner-runtime-lifecycle.md:69-71`).

**Missing live replacement/composition — High**

- Runtime owner, queue policy, capacity, command modes, and failure protocol cannot be replaced on a running host.
- No generic advisory hook exists around admission, execution, completion, or publication.
- No safe package-owned background publisher can update an independent channel.
- Public snapshots omit private publication provenance and delivery correlation.

**Plausible package needs**

Most packages should rely on, rather than replace, the serialized owner. Diagnostics, auditing, persistence, remote collaboration, or background analysis may need bounded observation or independent publication while preserving exact completion and failure identity.

### 5. State publication and subscriptions

**Current mechanism**

- A state root atomically contains revision, value, and private provenance (`tuna-racket/packages/tuna/private/runtime.rkt:49-55`).
- `state-changed` increments the revision exactly once, installs the new root, and coalesces subscriber wakes; `state-unchanged` publishes nothing (`tuna-racket/packages/tuna/private/runtime.rkt:557-572,738-777`).
- Subscribe-with-current is atomic. Wait returns the latest pending revision before end-of-file, preventing snapshot/subscribe gaps (`tuna-racket/packages/tuna/private/runtime.rkt:435-555`).
- The HTTP stream rereads the latest snapshot after a wake, so wake revision and delivered revision may differ under coalescing (`tuna-racket/packages/tuna/private/http.rkt:417-434`).

**Current policy**

- There is one authoritative root and one monotonically increasing outer revision.
- Publication is whole-root replacement; core exposes no deltas, dirty regions, sub-revisions, or deep immutability.
- Publication occurs before request completion (`tuna-racket/docs/adr/0002-live-registry-and-owner-runtime-lifecycle.md:23-33,63-71`).

**Missing live replacement/composition — High**

- No public changed-revision notification other than consuming a state subscription.
- No public correlation from command to changed root to later coalesced delivery.
- No package-owned auxiliary publication channel or independent invalidation.
- No atomic multi-root or package-resource transaction.

**Plausible package needs**

Packages may need their own generation/delta semantics, stale-result rejection, auxiliary status streams, or change observers. Editor research has not settled which operations require outer versus resource generations, synchronous versus coalesced observers, or visibility of aborted updates (`docs/tuna/research/research-gaps.md:189-210`).

### 6. Keymaps and input resolution

**Current mechanism**

- `tuna/keymap` provides immutable strokes, sequences, transition bindings, keymaps, and four resolution outcomes (`tuna-racket/packages/tuna/keymap.rkt:6-29`).
- Modifiers normalize to fixed canonical order; stroke domain and symbol code equality use symbol identity (`tuna-racket/packages/tuna/keymap.rkt:33-112`).
- A keymap cannot contain duplicate sequences or one sequence that prefixes another. Only the recursively frozen trie escapes construction (`tuna-racket/packages/tuna/keymap.rkt:181-280`).
- Ordered resolution gives the first exact, continuation, or explicit undefined result; absent falls through to lower maps (`tuna-racket/packages/tuna/keymap.rkt:282-337`).
- Transition binding argument specifications are deliberately opaque and retained by identity (`tuna-racket/packages/tuna/keymap.rkt:159-179`; `tuna-racket/packages/tuna/tests/keymap-test.rkt:47-55`).

**Current policy**

- Core does not own active keymaps. The counter example stores input policy, ordered maps, and pending sequence inside its package-defined root (`tuna-racket/packages/tuna-example-counter/private/counter-core.rkt:215-278`).
- The counter package owns DOM-key normalization, canonical modifier mapping, prefix state, argument acquisition, and target invocation (`tuna-racket/packages/tuna-example-counter/private/counter-core.rkt:26-213,287-347`).

**Missing live replacement/composition — Medium**

- Keymaps are immutable values, not live named cells; packages compose by constructing and storing ordered lists in application state.
- No generic mutation, parent-map graph, owner-aware contribution, context selection, or change notification exists.
- No core policy chooses maps by focus, subtree, mode, or connection—and current research says those scopes remain unsettled (`docs/tuna/research/research-gaps.md:27-65,304-327`).

**Plausible package needs**

Application packages can already own complete keymap policy, which respects the current product boundary. Multi-package applications may need an explicit package-level composition policy, but introducing mode/buffer/focus assumptions into core would freeze unresolved editor semantics.

### 7. Host construction and startup settings

**Current mechanism**

- `tuna/main` is the only public launcher entry. Host implementation is private (`tuna-racket/packages/tuna/main.rkt:3-10`; `tuna-racket/packages/tuna/tests/export-surface-test.rkt:78-81,112-142`).
- Live values select listener host/port, initial state, and keydown transition (`tuna-racket/packages/tuna/application.rkt:114-140`).
- Startup samples each exactly once after configuration. The selected transition **name** is fixed for that host, but redefining that name remains live at dequeue; the renderer is looked up live for every render (`tuna-racket/packages/tuna/main.rkt:63-80`; `tuna-racket/packages/tuna/private/render-support.rkt:61-69`).
- Listener, renderer, and transition validation precede runtime/service resource creation (`tuna-racket/packages/tuna/private/host.rkt:87-168`).

**Current policy**

- Listener policy is numeric IPv4 loopback `127.0.0.0/8`, port 1–65535 (`tuna-racket/packages/tuna/private/host.rkt:89-117`).
- Request read timeout is two seconds, body limit 65,536 bytes, SSE response timeouts are infinite, and server shutdown grace is two seconds (`tuna-racket/packages/tuna/private/host.rkt:25-29,360-367`).
- Host construction always allocates the integrated profiler even while its UI is disabled (`tuna-racket/packages/tuna/private/host.rkt:53-60,141-168`).

**Missing live replacement/composition — Blocker**

- No public host factory, host descriptor registry, package-instance factory, or activation point exists.
- Changing listener, initial-state, or transition-selection values after startup has no effect on the running host.
- Test parameters can replace factories and lifecycle operations, but they are private test seams, not extension contracts (`tuna-racket/packages/tuna/private/host.rkt:70-82,411-430`).

**Plausible package needs**

Packages owning threads, subscriptions, caches, files, or other resources need host-instance activation, deterministic shutdown participation, partial-start cleanup, and diagnostics. Once-only module initialization is not host activation and provides no reactivation or cleanup handle (`docs/tuna/profiler-extraction-research.md:361-376`).

### 8. HTTP routing, responses, and assets

**Current mechanism**

- The route table is a private fixed `cond`: `/`, `/subscribe`, `/profile/subscribe`, and two exact asset paths (`tuna-racket/packages/tuna/private/http.rkt:550-585`).
- Finite responses fix no-store text/page caching; assets use immutable year-long caching (`tuna-racket/packages/tuna/private/http.rkt:30-54,453-469`).
- Assets are resolved module-relatively, loaded once into immutable bytes, and are independent of current working directory (`tuna-racket/packages/tuna/asset-paths.rkt:1-12`; `tuna-racket/packages/tuna/private/web-assets.rkt:3-21`).
- Datastar public `datastar-sse`, `patch-elements`, and `datastar-tcp@` own response lifecycle and disconnect handling (`tuna-racket/docs/adr/0005-public-datastar-sse-lifecycle.md:15-29`).

**Current policy**

- Methods, `Allow` headers, response bodies, selectors, cache behavior, and error precedence are exact current contracts (`tuna-racket/docs/adr/0003-web-datastar-response-and-web-07-deviation.md:109-123`).
- State and profiler subscriptions are acquired inside response callbacks. Shutdown/capacity rejection after response creation ends the stream rather than producing a pre-response 503, per superseding ADR 0005 (`tuna-racket/docs/adr/0005-public-datastar-sse-lifecycle.md:23-29,37-45`).

**Missing live replacement/composition — Blocker**

- No public route registration, sub-handler mount, middleware, asset contribution, request decoder registry, or response policy extension.
- A package cannot expose an independent endpoint without replacing the whole private handler or modifying core.
- Route and selector ownership are not represented, so conflict detection or stale cleanup is impossible.

**Plausible package needs**

Some packages may require independent endpoints or assets; others could use generic page/auxiliary publication. Current evidence does not establish that a general route registry is necessary, so route registration and shared auxiliary transport remain materially different possibilities (`docs/tuna/profiler-extraction-research.md:37-50,407-408`).

### 9. Rendering and page composition

**Current mechanism**

- `tuna-render-state` is one live function with a fixed one-snapshot wrapper (`tuna-racket/packages/tuna/render.rkt:6-18`).
- Each call captures one generation, passes an opaque snapshot containing revision and state, and requires a string result (`tuna-racket/packages/tuna/private/render-support.rkt:27-44,61-70`).
- Renderer output is trusted raw markup. The fixed shell is split before fragments are appended so fragment contents cannot be interpreted as compositor slots (`tuna-racket/packages/tuna/private/http.rkt:322-341`).
- The state fragment must serve as complete outer replacement for `#state` (`tuna-racket/packages/tuna/private/datastar-sse.rkt:28-31`).

**Current policy**

- Default rendering produces one escaped `<pre id="state">` fragment (`tuna-racket/packages/tuna/private/render-support.rkt:46-59`).
- The page fixes title, import map, keyboard asset, global keydown handler, state slot, and profiler-specific style/body/stream slots (`tuna-racket/packages/tuna/private/http.rkt:343-387`).
- Trusted configuration is responsible for renderer safety; renderer markup is intentionally not escaped (`tuna-racket/packages/tuna/tests/http-contract-test.rkt:152-175`).

**Missing live replacement/composition — Blocker**

- Whole-renderer replacement is live, but independent renderer packages cannot contribute safely without coordinating inside that one function.
- There is no dispatch protocol over package-defined node values, no renderer contribution ownership, and no head/body/initialization composition.
- No package can independently invalidate a fragment after a state-unchanged command.
- The fixed profiler slots are a one-off integration, not an open composition model.

**Plausible package needs**

Packages may need renderer dispatch over concrete tree values, shared page resources, and independently replaceable fragments. The current working model explicitly leaves generic node dispatch and cross-package renderer composition unsettled (`docs/tuna/research/working-model.md:72-82,97-109`).

### 10. Configuration, loading, and installed packages

**Current mechanism**

- Configuration is a sequence of ordinary Racket forms, not a module. All forms are read before any evaluation with reader, language, and compiled inputs disabled (`tuna-racket/packages/tuna/config.rkt:14-26`).
- Evaluation occurs sequentially in a retained namespace sharing Tuna’s module registry. Explicit `require` affects later forms and transformers (`tuna-racket/packages/tuna/config.rkt:37-64`).
- Reader failure applies no forms; later expansion/runtime failure preserves earlier effects and re-raises the exact value with enclosing-form diagnostics (`tuna-racket/packages/tuna/config.rkt:28-51`; `tuna-racket/docs/adr/0001-controlled-configuration-trust-and-evaluation.md:13-21`).
- Installation is the plugin/deployment model. Independently installed compiled modules and transformers resolve through Racket collections and initialize once (`tuna-racket/docs/adr/0004-package-topology-and-open-installed-extensions.md:108-113,249-257`).
- CLI accepts only no arguments, `--config FILE`, or `--no-config`; default selection follows XDG, HOME, then installation-root fallback (`tuna-racket/packages/tuna/startup.rkt:8-48`).

**Current policy**

- Configuration is trusted arbitrary code: no sandbox, transaction, rollback, implicit prelude, custom language, or concurrent loading protocol (`tuna-racket/docs/adr/0001-controlled-configuration-trust-and-evaluation.md:5-21,32-40`).
- Namespaces are retained for application lifetime and never unloaded.
- A finite standalone executable is intentionally not equivalent to open installed extensions (`tuna-racket/docs/adr/0004-package-topology-and-open-installed-extensions.md:108-113`).

**Missing live replacement/composition — High**

- Configuration runs only during launcher startup in production.
- No reload, unload, deactivation, reverse-order rollback, or concurrent-load contract exists.
- Requiring a module once does not provide per-host activation or replacement.
- Partial configuration effects may leave several successful registrations after later failure.

**Plausible package needs**

Existing configuration can import a package and call explicit activation code. Packages needing coherent multi-surface activation require ownership and cleanup beyond the loader; this must not be confused with making the whole configuration transactional.

### 11. Lifecycle and resource ownership

**Current mechanism**

- `main` establishes logging first, nests host ownership inside it, and retains the first arbitrary failure while still attempting cleanup (`tuna-racket/packages/tuna/main.rkt:25-35,37-95`).
- Host startup serializes service start, web-server creation, shutdown-authority publication, listener confirmation, logging, and started publication (`tuna-racket/packages/tuna/private/host.rkt:323-399`).
- Service shutdown closes ingress, waits for in-flight admission, stops and joins runtime, closes the profiler, closes and joins the observer, checks retained capacity/diagnostics, and preserves failure precedence (`tuna-racket/packages/tuna/private/completion-observer.rkt:594-680`).
- Host cleanup then invokes server shutdown and emits its final log, attempting all stages (`tuna-racket/packages/tuna/private/host.rkt:224-255`).
- SSE callbacks own exactly one acquired subscription and release it through Datastar’s close callback (`tuna-racket/packages/tuna/private/http.rkt:504-548`; `tuna-racket/packages/tuna/private/datastar-sse.rkt:11-26`).

**Current policy**

- Normal stop is close-ingress, drain accepted work, close subscriptions/streams, and join owned resources; forced kill, break, or custodian shutdown is not the normal protocol (`tuna-racket/docs/adr/0002-live-registry-and-owner-runtime-lifecycle.md:23-33,69-71`).
- First-failure precedence and exact ownership are pervasive invariants.

**Missing live replacement/composition — Blocker**

- Lifecycle ordering names only core service, profiler, observer, server, and logging resources.
- No public registration lets a package contribute a factory, close ingress, drain, join, diagnose, or revoke partial activation.
- No generation/owner identity prevents stale cleanup from removing a replacement.

**Plausible package needs**

Any package owning processes, threads, ports, subscriptions, caches, or watchers needs bounded ownership integrated with host start/stop. Advisory package failure must be isolated from authoritative command results while remaining diagnosable.

### 12. Logging and diagnostics

**Current mechanism**

- Public API exposes only `initialize-logging!`, `shutdown-logging!`, `log-info`, and `log-error` (`tuna-racket/packages/tuna/log.rkt:3-6`).
- Initialization samples `GERBIL_LOG_LEVEL`, captures the current error port, creates one Racket log receiver and sink thread, and publishes one global accepting state (`tuna-racket/packages/tuna/log.rkt:55-88,103-134`).
- Shutdown closes ingress, drains queued events, joins the sink, and is retryable after interruption (`tuna-racket/packages/tuna/log.rkt:136-162`).
- Emission is structured as Racket vectors with topic `tuna`; calls before initialization or after ingress closes are dropped (`tuna-racket/packages/tuna/log.rkt:164-191`).

**Current policy**

- Compatibility levels and overrides use historical `GERBIL_LOG_LEVEL` syntax.
- Only info/error entry points exist. All public messages use source/topic `tuna`; packages cannot supply their own source for exact/prefix policy.
- Write failures are suppressed (`tuna-racket/packages/tuna/log.rkt:90-101`).

**Missing live replacement/composition — High**

- No live value selects level, sink, formatter, topic, or destination.
- No multiple sinks, package source identity, diagnostic registry, or host-owned package logging lifecycle.
- The observer service has a private replaceable log operation, but it is not a package seam (`tuna-racket/packages/tuna/private/completion-observer.rkt:221-231,338-365`).

**Plausible package needs**

Packages may need structured source identity, bounded diagnostic retention, independent sinks, and lifecycle reporting. Logging replacement and retained lifecycle diagnostics are materially different concerns and should not be conflated.

### 13. Integrated profiler as a boundary warning

**Current mechanism/policy**

- Public profiler API is only `tuna-profiler-enabled` and `with-profile-span` (`tuna-racket/packages/tuna/profiler.rkt:7-22`).
- Core nevertheless carries profiler-specific observations through command requests, state provenance, detailed snapshots, delivery rendering/sending, HTTP routing, page slots, coordinator capacity, and shutdown (`docs/tuna/profiler-extraction-research.md:17-43`).
- The coordinator fixes 64 delivery reservations, 64 subscriptions, latest-command behavior, and profiler-specific snapshots (`tuna-racket/packages/tuna/private/profiler-coordinator.rkt:41-64,500-516,580-639`).
- The profiler renderer fixes `#tuna-profiler`, inline CSS, status vocabulary, and tree markup (`tuna-racket/packages/tuna/private/profiler-render.rkt:12-95`).

**Gap — Blocker**

This is not evidence for a general one-observer slot, span API, profiler lifecycle phase, detailed timed snapshot, or fixed auxiliary selector. The existing research explicitly classifies those as disguised profiler interfaces and requires any generic seam to be validated with materially different non-profiler behavior (`docs/tuna/profiler-extraction-research.md:628-650`).

## Indirection patterns and their limits

| Pattern | What it supports now | What it does not support |
|---|---|---|
| Stable live cell | Same-name replacement across compiled callers | Multiple owners, advice, registration ordering, stale cleanup |
| Immutable caller-owned value | Keymap/state-tree composition under package policy | Live notification or coordinated replacement |
| Startup-sampled live value | Configuration-time selection | Running-host reselection |
| Fixed private factory parameter | Deterministic unit/fault testing | Public package extension |
| Explicit event object | Ordered named callbacks | Production hook publication, resource ownership, contained advisory failure |
| Whole-renderer replacement | Complete application-owned markup | Cross-package page/render composition |
| Once-only module initialization | Installed package discovery and stable module identity | Host activation, deactivation, reload, cleanup |

## Test inventory and redesign constraints

### Strong existing coverage

- Exact public exports are locked for every public module and the prelude (`tuna-racket/packages/tuna/tests/export-surface-test.rkt:21-108,112-171`).
- Bindings tests cover stable snapshots, live wrappers versus captures, coherent action generations, aliases, copied descriptors, value redefinition, dynamic binding, and value contexts (`tuna-racket/packages/tuna/tests/bindings-test.rkt:23-240` and subsequent context cases).
- Runtime tests cover bounded FIFO admission, dequeue-time replacement, contexts, arbitrary failure identity, state outcomes, publication, subscriptions, concurrent producers, and owner cleanup (`tuna-racket/packages/tuna/tests/runtime-test.rkt:54-385`).
- HTTP tests lock strict decoding, page trust boundary, routes/methods/cache headers, callback-scoped subscriptions, precedence, registration-before-204, 503 mapping, and observer saturation (`tuna-racket/packages/tuna/tests/http-contract-test.rkt:111-417`).
- Process tests cover actual loopback routes, request bounds/timeouts, accepted failure followed by later work, idle SSE shutdown, disconnect isolation, address reuse, launcher behavior, and log draining (`tuna-racket/tests/process/server-lifecycle-test.rkt:166-276`; `tuna-racket/tests/process/sse-lifecycle-test.rkt:263-406`; `tuna-racket/tests/process/launcher-test.rkt:118-169`; `tuna-racket/tests/process/logging-test.rkt:17-61`).
- Configuration tests cover read-all semantics, disabled readers, sequential imports, retained namespace state, partial effects, transformer replacement, compiled callers, and shared registry identity (`tuna-racket/packages/tuna/tests/config-test.rkt:163-461`).
- Counter integration proves queued dispatch uses the latest state-held map and latest live transition target (`tuna-racket/tests/integration/counter-dispatch-test.rkt:50-126`).
- Package examples prove same-name callable/value coexistence, automatic locality, host-neutral actions, once-only initialization, and compiled-call live replacement (`tuna-racket/packages/tuna-example-message/tests/main-test.rkt:8-38`; `tuna-racket/packages/tuna-example-dummy/tests/main-test.rkt:9-58`).

### Test constraints for a clean break

- Exact-export, exact-route, exact-page, profiler, and package-topology tests intentionally encode the present surface; they are change detectors, not evidence that those policies belong in the new core.
- Private factory parameters and fault setters are test seams only. Promoting them directly would expose implementation-shaped interfaces.
- Existing state/runtime tests are valuable invariants to retain: bounded admission, one owner, dequeue-time name lookup, publication-before-completion, exact failure identity, coalescing, pending-before-EOF, and deterministic drain/join.
- Existing package tests demonstrate replacement, not multi-package composition, ownership, live host replacement, or deactivation.

## Evidence-backed candidate validation

Any later redesign can be checked without assuming editor concepts or profiler shapes by demonstrating:

1. Two materially different installed packages contribute simultaneously without either replacing the other.
2. Later live redefinition updates named callbacks while stale cleanup cannot erase the newer definition.
3. A non-profiler advisory package observes bounded command/publication behavior without changing command results or failure identity.
4. A package-owned independently changing fragment can wake, render, disconnect, and stop without requiring an application-state metadata map.
5. Package activation failure cleans only its owned resources and preserves the original failure.
6. Core installs, starts, accepts commands, publishes state, renders, and stops when optional packages—including the profiler—are absent.
7. Browser-message experiments cover at least one non-keydown/IME-capable path before an editor input contract is frozen.
8. Existing bounded runtime, subscription, SSE, listener-reuse, and first-failure lifecycle tests continue to pass.

These checks follow the existing genericity and negative-capability evidence in `docs/tuna/profiler-extraction-research.md:999-1039`.

## Residual risks and confidence

- **Blocker:** fixed HTTP/input/page/lifecycle surfaces prevent independent package composition.
- **High:** startup-sampled selection values appear “live” in configuration but do not reselect a running host.
- **High:** mutable application roots are not deep-frozen; packages must preserve publication discipline.
- **High:** input, focus, mode, local-keymap, generation, and structural-tree semantics remain deliberately unresolved.
- **Medium:** the repository’s exact export and route tests will report intended clean-break changes as failures until their contracts are deliberately superseded.
- The workbench Git root currently treats the repository contents as untracked, limiting useful diff attribution, but `git diff --cached --name-only` confirmed no staged files.
- No Racket tests or servers were run; findings are source-, test-, ADR-, and documentation-based.

**Confidence:** high for the current production topology and missing public seams; medium for package needs that depend on unresolved editor/input product decisions.