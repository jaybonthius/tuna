# Profiler extraction research

Status: research evidence, not an architecture decision or implementation plan.

Scope: current `/home/jay/Code/workbench-racket/tuna-racket` source and tests,
plus selective primary Emacs source. This note does not design editor, layout,
document, or text APIs.

## Claim labels

- **Observed fact** — directly supported by cited source.
- **Inference** — conclusion drawn from observed facts; not yet a decided
  contract.
- **Proposal** — candidate seam, alternative, experiment, or decision for later
  evaluation.

## Executive finding

**Observed fact.** The current profiler is not an optional layer. Core always
constructs it and carries profiler-specific data through host construction,
command admission, owner execution, state publication, state delivery, HTTP
routing, page composition, Server-Sent Events (SSE), rendering, and shutdown.
Its public Racket export surface is only `tuna-profiler-enabled` and
`with-profile-span`; its separately observable HTTP/page surface also includes
the panel and `/profile/subscribe`. Its private integration is broad
([`packages/tuna/profiler.rkt:3-22`](../../tuna-racket/packages/tuna/profiler.rkt),
[`packages/tuna/private/host.rkt:36-60,141-168`](../../tuna-racket/packages/tuna/private/host.rkt),
[`packages/tuna/private/runtime.rkt:41-55,646-770`](../../tuna-racket/packages/tuna/private/runtime.rkt),
[`packages/tuna/private/http.rkt:322-387,389-444,471-585`](../../tuna-racket/packages/tuna/private/http.rkt)).

**Inference.** A true extraction with zero profiler-specific core references
cannot be achieved by moving the coordinator and renderer files alone. It must
remove profiler vocabulary and types from core while preserving only generic
mechanical contracts for observation, publication, transport, failure,
redefinition, and lifecycle.

**Inference.** A profiler-specific route and profiler data in application state
are not logical requirements. They are properties of the current implementation.
Accurate extraction does require an externally usable way to observe commands,
correlate a changed revision with its later delivery, publish an independently
changing diagnostic fragment, and clean up package-owned resources. Those
capabilities could be supplied without either a general route registry or
editor-state injection.

**Proposal.** The smallest credible generic direction to test is a host-owned,
keyed extension registration combined with narrow advisory command/publication/
delivery observation and a generic auxiliary page-fragment publication
mechanism. General HTTP route registration and whole-handler middleware should
remain alternatives until an experiment proves that an independent route is
necessary.

---

## 1. Current dependency and touchpoint map

### 1.1 Profiler-owned implementation

| Area | Evidence | Classification |
|---|---|---|
| Public switch and span form | `tuna/profiler` defines the live `tuna-profiler-enabled` value, default `#f`, and `with-profile-span`; the macro avoids evaluating its description when no profiler context is active ([`packages/tuna/profiler.rkt:3-22`](../../tuna-racket/packages/tuna/profiler.rkt)). | **Observed fact** |
| Clock | A private monotonic clock abstraction computes floored microseconds ([`packages/tuna/private/profile-clock.rkt:3-38`](../../tuna-racket/packages/tuna/private/profile-clock.rkt)). | **Observed fact** |
| Dynamic span frontend | A thread-owner-scoped parameter carries admit/finish callbacks; descriptions are capped at 128 characters; observer faults are contained; finalization uses `dynamic-wind` ([`packages/tuna/private/profiler-frontend.rkt:3-55,57-122`](../../tuna-racket/packages/tuna/private/profiler-frontend.rkt)). | **Observed fact** |
| Observation tree | Span builders, readiness tokens, delivery spans, immutable snapshots, status vocabulary, and a 512-node bound are profiler data structures ([`packages/tuna/private/observation.rkt:7-64,74-181`](../../tuna-racket/packages/tuna/private/observation.rkt)). Admission, owner, completion, and readiness are recorded at [`observation.rkt:187-403`](../../tuna-racket/packages/tuna/private/observation.rkt); snapshots and snapshot/render/send delivery phases are built at [`observation.rkt:405-562`](../../tuna-racket/packages/tuna/private/observation.rkt). | **Observed fact** |
| Latest-command coordinator | The coordinator owns one current profile, generations, snapshots, command admission, delivery reservations, subscriptions, rollback, close, and retained-capacity diagnostics ([`packages/tuna/private/profiler-coordinator.rkt:3-64,66-422,424-879`](../../tuna-racket/packages/tuna/private/profiler-coordinator.rkt)). Delivery and subscription capacities are each 64 (`:41-42,500-516,610-634`). | **Observed fact** |
| Profiler renderer | The renderer owns the fixed inline CSS, `#tuna-profiler` markup, stable node IDs, sanitized descriptions, timing/status markers, and omitted-span display ([`packages/tuna/private/profiler-render.rkt:3-95`](../../tuna-racket/packages/tuna/private/profiler-render.rkt)). | **Observed fact** |

**Inference.** These modules are cohesive enough to move to a separate package
only after their inputs and ownership cease to be profiler-specific core fields
and calls.

### 1.2 Core runtime and state publication

- **Observed fact.** Core runtime directly imports the profiler clock,
  observation, and frontend modules
  ([`packages/tuna/private/runtime.rkt:3-8`](../../tuna-racket/packages/tuna/private/runtime.rkt)).
- **Observed fact.** `command-request` contains an observation; `state-root`
  contains provenance; each state subscription contains `may-be-profiled?`
  ([`runtime.rkt:41-55`](../../tuna-racket/packages/tuna/private/runtime.rkt)).
- **Observed fact.** A private observed-transition submission path attaches an
  observation to an accepted request
  ([`runtime.rkt:287-360`](../../tuna-racket/packages/tuna/private/runtime.rkt)).
- **Observed fact.** `command-runtime-detailed-snapshot` accepts a profile clock,
  times snapshot acquisition, clears a profiler hint, and returns revision,
  state, provenance, and two ticks
  ([`runtime.rkt:376-433`](../../tuna-racket/packages/tuna/private/runtime.rkt)).
- **Observed fact.** Changed roots retain profiler provenance and profiler hints
  are placed on invalidated state subscriptions
  ([`runtime.rkt:557-572`](../../tuna-racket/packages/tuna/private/runtime.rkt)).
- **Observed fact.** Owner-side action/transition execution and changed-state
  publication are wrapped in profiler contexts and spans
  ([`runtime.rkt:646-735`](../../tuna-racket/packages/tuna/private/runtime.rkt)).
- **Observed fact.** Completion readiness is kept pending until the profiler
  observation is terminal
  ([`runtime.rkt:685-701`](../../tuna-racket/packages/tuna/private/runtime.rkt)).
- **Observed fact.** The public `tuna/runtime` facade does not expose observed
  submission, detailed snapshots, provenance, or profiler clocks
  ([`packages/tuna/runtime.rkt:3-60`](../../tuna-racket/packages/tuna/runtime.rkt)).

**Inference.** Accurate correlation currently depends on profiler data embedded
in private command and state-publication structures. An external package cannot
reproduce admission-to-delivery profiles through the public runtime API.

### 1.3 Completion observation and service ownership

- **Observed fact.** The completion-observer service imports profiler modules,
  stores an optional coordinator, accepts `#:profiler`, and exposes the
  coordinator through an accessor
  ([`packages/tuna/private/completion-observer.rkt:3-32,42-60,99-133`](../../tuna-racket/packages/tuna/private/completion-observer.rkt)).
- **Observed fact.** Its profiler-specific detailed snapshot gets the
  coordinator clock and calls the runtime's profiler-specific snapshot path
  ([`completion-observer.rkt:147-177`](../../tuna-racket/packages/tuna/private/completion-observer.rkt)).
- **Observed fact.** Profiled and unprofiled commands share admission machinery,
  but profiled submission validates coordinator ownership and selects an
  observed runtime operation
  ([`completion-observer.rkt:468-570`](../../tuna-racket/packages/tuna/private/completion-observer.rkt)).
- **Observed fact.** Service shutdown closes profiler ingress, drains and joins
  the runtime, closes the profiler, then closes and joins the completion
  observer; profiler cleanup failure and retained capacity participate in
  terminal failure selection
  ([`completion-observer.rkt:594-680`](../../tuna-racket/packages/tuna/private/completion-observer.rkt)).

**Inference.** The missing external capability is not simply a stop hook. The
profiler owns work that must stop accepting input before runtime drain and must
be closed after correlated work becomes terminal. A generic lifecycle model
must express dependency/ownership ordering without exposing phases named for the
profiler.

### 1.4 Host construction and lifecycle

- **Observed fact.** Every host contains `profiler` as a struct field, always
  calls `current-host-profiler-maker`, and passes the result to the service even
  when profiling is disabled
  ([`packages/tuna/private/host.rkt:36-60,70-79,141-168`](../../tuna-racket/packages/tuna/private/host.rkt)).
- **Observed fact.** The enable flag therefore controls sampling and UI, not
  allocation or profiler participation in lifecycle.
- **Observed fact.** Host startup validates listener, renderer, and transition
  before runtime/service allocation; startup publishes cleanup authority before
  interruptible checkpoints; shutdown attempts all stages and retains the first
  failure
  ([`host.rkt:119-168,181-258,323-399`](../../tuna-racket/packages/tuna/private/host.rkt)).
- **Observed fact.** The existing host profiler maker and lifecycle callbacks
  are private `test-support` parameters, not public extension APIs
  ([`host.rkt:411-422`](../../tuna-racket/packages/tuna/private/host.rkt)).

**Inference.** A separately installed profiler needs host-scoped activation and
cleanup, not a process-global coordinator constructed at module load.

### 1.5 HTTP routing and command ingress

- **Observed fact.** The HTTP module directly imports public and private profiler
  modules
  ([`packages/tuna/private/http.rkt:3-17`](../../tuna-racket/packages/tuna/private/http.rkt)).
- **Observed fact.** Profiler enablement is a strict live-value sample and is
  sampled separately for page rendering, each successfully decoded POST, and
  the profiler subscription route
  ([`http.rkt:367-387,482-499,524-548`](../../tuna-racket/packages/tuna/private/http.rkt)).
- **Observed fact.** A decoded keydown POST constructs the root description,
  begins a command profile before service submission, and chooses a
  profiler-specific submission operation
  ([`http.rkt:471-502`](../../tuna-racket/packages/tuna/private/http.rkt)).
- **Observed fact.** `GET /profile/subscribe` is hard-coded; wrong methods return
  405 before enablement is considered; disabled or absent profiler returns 503
  ([`http.rkt:53-54,524-548,550-585`](../../tuna-racket/packages/tuna/private/http.rkt)).
- **Observed fact.** There is no public route registry or public HTTP-handler
  composition API; the route conditional and handler constructor are private
  ([`http.rkt:550-585`](../../tuna-racket/packages/tuna/private/http.rkt)).

**Inference.** The current route cannot move out of core without either a route
composition seam or a different transport for auxiliary fragment updates.
That does not prove that general route registration is the best or smallest
seam.

### 1.6 State delivery and rendering

- **Observed fact.** The generic state renderer is already a live callable. It
  receives a snapshot containing only revision and opaque state, and must return
  a string
  ([`packages/tuna/render.rkt:6-18`](../../tuna-racket/packages/tuna/render.rkt),
  [`packages/tuna/private/render-support.rkt:5-42,56-69`](../../tuna-racket/packages/tuna/private/render-support.rkt)).
- **Observed fact.** State streaming currently obtains a profiler-detailed
  snapshot, correlates provenance, records snapshot/render/send phases, and
  finalizes a delivery status
  ([`packages/tuna/private/http.rkt:389-434`](../../tuna-racket/packages/tuna/private/http.rkt)).
- **Observed fact.** A separate profiler stream sends an initial profiler
  snapshot and coalesced updates
  ([`http.rkt:436-444`](../../tuna-racket/packages/tuna/private/http.rkt)).
- **Observed fact.** `patch-profiler!` is a fixed helper that outer-replaces
  `#tuna-profiler`; it shares Datastar's generic callback-owned SSE lifecycle
  with state streaming
  ([`packages/tuna/private/datastar-sse.rkt:3-36`](../../tuna-racket/packages/tuna/private/datastar-sse.rkt)).

**Inference.** Replacing `tuna-render-state` can embed a panel in initial and
state-update markup, but it cannot make the existing state subscription wake
when only profiler data changes. It also cannot observe send completion. Renderer
replacement alone therefore cannot preserve the current latest-command display.

### 1.7 Page composition and assets

- **Observed fact.** The fixed page shell contains profiler style and fragment
  sentinels and conditionally adds `@get('/profile/subscribe', ...)`
  ([`packages/tuna/private/http.rkt:322-365`](../../tuna-racket/packages/tuna/private/http.rkt)).
- **Observed fact.** Trusted profiler CSS and the initial panel fragment are
  inserted by a raw-string compositor
  ([`http.rkt:328-341,370-387`](../../tuna-racket/packages/tuna/private/http.rkt)).
- **Observed fact.** The profiler has no separate static browser asset. Its CSS
  is inline. Core's only committed runtime-path assets are Datastar and the
  keyboard module
  ([`packages/tuna/private/profiler-render.rkt:12-15`](../../tuna-racket/packages/tuna/private/profiler-render.rkt),
  [`packages/tuna/asset-paths.rkt:1-12`](../../tuna-racket/packages/tuna/asset-paths.rkt),
  [`packages/tuna/private/web-assets.rkt:3-21`](../../tuna-racket/packages/tuna/private/web-assets.rkt)).

**Inference.** Extraction does not by itself justify a static-asset registry.
An external package can retain inline CSS, or own module-relative assets and
serve them through whatever generic transport is eventually selected.

### 1.8 Configuration and public API

- **Observed fact.** `tuna/prelude` imports and re-exports both profiler names,
  so ordinary prelude import instantiates profiler code
  ([`packages/tuna/prelude.rkt:3-10,60-61`](../../tuna-racket/packages/tuna/prelude.rkt)).
- **Observed fact.** The example configuration enables profiling through the
  live value API
  ([`examples/config.rkt:1-9,19`](../../tuna-racket/examples/config.rkt)).
- **Observed fact.** Export tests pin `tuna/profiler`, the two public names, and
  the absence of private profiler helpers from public modules
  ([`packages/tuna/tests/export-surface-test.rkt:62-64,101-170`](../../tuna-racket/packages/tuna/tests/export-surface-test.rkt)).
- **Observed fact.** Documentation presents the profiler as a core public module
  and as development-only, disabled by default, bounded, and fail-open
  ([`README.md:47-61,66-86`](../../tuna-racket/README.md)).
- **Observed fact.** ADR 0004 fixes the current four-package topology, with
  profiler code inside `tuna`; a fifth optional package changes that accepted
  topology
  ([`docs/adr/0004-package-topology-and-open-installed-extensions.md:13-26`](../../tuna-racket/docs/adr/0004-package-topology-and-open-installed-extensions.md)).

**Inference.** “Zero profiler-specific references in core” implies moving the
public vocabulary too. Keeping `tuna-profiler-enabled` or `with-profile-span` in
core as compatibility shims would not meet the literal boundary. The new
collection name and compatibility policy are owner decisions.

### 1.9 Lifecycle contract and tests

**Observed fact.** Current behavior is distributed across these test surfaces:

- frontend/span behavior:
  [`packages/tuna/tests/profiler-test.rkt:1-214`](../../tuna-racket/packages/tuna/tests/profiler-test.rkt);
- clock, bounds, trees, delivery, subscriptions, provenance, and rendering:
  [`packages/tuna/tests/private/profiler-core-test.rkt:1-784`](../../tuna-racket/packages/tuna/tests/private/profiler-core-test.rkt);
- fail-open faults, rollback, breaks, and cleanup precedence:
  [`packages/tuna/tests/private/profiler-fault-test.rkt:1-711`](../../tuna-racket/packages/tuna/tests/private/profiler-fault-test.rkt);
- service admission, capacity, stop races, and stream closure:
  [`packages/tuna/tests/private/profiler-service-test.rkt:1-305`](../../tuna-racket/packages/tuna/tests/private/profiler-service-test.rkt);
- runtime provenance/readiness fault boundaries:
  [`packages/tuna/tests/private/runtime-fault-test.rkt:202-362`](../../tuna-racket/packages/tuna/tests/private/runtime-fault-test.rkt);
- page, route, enablement, HTTP status, and callback acquisition:
  [`packages/tuna/tests/http-contract-test.rkt:71-93,152-262`](../../tuna-racket/packages/tuna/tests/http-contract-test.rkt);
- Datastar selector and outer-frame behavior:
  [`packages/tuna/tests/datastar-frame-test.rkt:38-58`](../../tuna-racket/packages/tuna/tests/datastar-frame-test.rkt);
- asset-handler fixture:
  [`packages/tuna/tests/asset-test.rkt:60-85`](../../tuna-racket/packages/tuna/tests/asset-test.rkt);
- public/private export boundaries:
  [`packages/tuna/tests/export-surface-test.rkt:62-64,101-170`](../../tuna-racket/packages/tuna/tests/export-surface-test.rkt);
- real HTTP/SSE disconnect, replacement, update, shutdown, and address reuse:
  [`tests/process/sse-lifecycle-test.rkt:246-410`](../../tuna-racket/tests/process/sse-lifecycle-test.rkt).

**Observed fact.** ADR 0005 is the current SSE lifecycle decision: each callback
acquires and owns one state or profiler subscription; shutdown of the runtime or
coordinator wakes streams; disabled profiler requests retain 503; capacity
rejection ends an already-started SSE response
([`docs/adr/0005-public-datastar-sse-lifecycle.md:17-33,38-58`](../../tuna-racket/docs/adr/0005-public-datastar-sse-lifecycle.md)).
ADR 0003 remains useful for route, selector, and trusted-markup evidence but its
older private Datastar lifecycle is superseded
([`docs/adr/0003-web-datastar-response-and-web-07-deviation.md:1-3`](../../tuna-racket/docs/adr/0003-web-datastar-response-and-web-07-deviation.md)).

---

## 2. Existing usable extension mechanisms

### 2.1 Installed packages and trusted configuration

- **Observed fact.** Installation is Tuna's plugin/deployment model. Trusted
  configuration can explicitly import independently installed compiled modules
  and transformers through the Racket collection resolver; core does not depend
  on examples
  ([`docs/adr/0004-package-topology-and-open-installed-extensions.md:5-25,108-114,253-257`](../../tuna-racket/docs/adr/0004-package-topology-and-open-installed-extensions.md)).
- **Observed fact.** `load-config!` reads all forms first, then evaluates them
  sequentially in a retained namespace sharing Tuna's module registry. Earlier
  completed effects survive later expansion/runtime failure. There is no
  rollback, unload, or concurrent loading protocol
  ([`packages/tuna/config.rkt:5-7,9-25,35-64`](../../tuna-racket/packages/tuna/config.rkt),
  [`docs/adr/0001-controlled-configuration-trust-and-evaluation.md:13-21,36-40`](../../tuna-racket/docs/adr/0001-controlled-configuration-trust-and-evaluation.md)).

**Inference.** Configuration can import a separate profiler package and call one
activation form without any new loader. It cannot by itself provide host
ownership, cleanup, or the missing runtime/HTTP callbacks.

### 2.2 Live functions and values

- **Observed fact.** Tuna has separate stable live callable and value cells,
  aliases, logical removal, descriptors, dynamic values, explicit contexts, and
  automatically local values
  ([`packages/tuna/bindings.rkt:3-34,46-123,328-824`](../../tuna-racket/packages/tuna/bindings.rkt)).
- **Observed fact.** Function, action, and transition definitions replace one
  complete generation in a stable cell; definition-site wrappers reread that
  cell, while `function-ref` captures one implementation
  ([`bindings.rkt:178-327`](../../tuna-racket/packages/tuna/bindings.rkt),
  [`docs/adr/0002-live-registry-and-owner-runtime-lifecycle.md:13-18`](../../tuna-racket/docs/adr/0002-live-registry-and-owner-runtime-lifecycle.md)).
- **Observed fact.** `defun`, `defaction`, `deftransition`, `defvar`, and
  `value-set!` expose these mechanisms to configuration
  ([`packages/tuna/prelude.rkt:125-291`](../../tuna-racket/packages/tuna/prelude.rkt)).

**Inference.** A profiler package can own its enable value, renderer helpers,
span form, and named callbacks in its own collection. Live cells also provide a
model for same-owner redefinition, but they do not currently support advice or
owned multi-contribution registration.

### 2.3 Actions and transitions

- **Observed fact.** Actions bundle implementation, host descriptor, argument
  acquisition, and documentation in one live generation; transitions are
  live named functions over opaque state
  ([`packages/tuna/bindings.rkt:187-209,268-327`](../../tuna-racket/packages/tuna/bindings.rkt)).
- **Observed fact.** Core owner execution selects action/transition generations
  at dequeue time
  ([`packages/tuna/private/runtime.rkt:630-669`](../../tuna-racket/packages/tuna/private/runtime.rkt)).

**Inference.** These mechanisms let a package define profiled commands and
transitions. They do not let it observe every command's admission, queueing,
completion, publication, or delivery without replacing configured behavior.

### 2.4 Events

- **Observed fact.** `tuna/event` supplies explicit event objects, named
  listener identity, duplicate rejection, ordered execution, removal, and
  live lookup for symbol listeners
  ([`packages/tuna/event.rkt:5-81`](../../tuna-racket/packages/tuna/event.rkt)).
- **Observed fact.** Production core does not publish command, publication,
  delivery, host-start, or host-stop events through this module; uses outside
  `event.rkt` are tests.
- **Observed fact.** Listener failures propagate from `event-run!`, return values
  are ignored, and events have no resource ownership or automatic cleanup
  (`event.rkt:69-81`).

**Inference.** The event implementation offers useful identity and ordering
precedent, but existing events are not sufficient extraction seams.

### 2.5 Render replacement and opaque state

- **Observed fact.** Configuration can supply the complete initial opaque state,
  select a transition name, and replace `tuna-render-state`
  ([`packages/tuna/application.rkt:116-140`](../../tuna-racket/packages/tuna/application.rkt),
  [`examples/config.rkt:6-9`](../../tuna-racket/examples/config.rkt)).
- **Observed fact.** Startup snapshots initial state and transition after
  configuration; rendering remains live on each call
  ([`packages/tuna/main.rkt:63-80`](../../tuna-racket/packages/tuna/main.rkt),
  [`packages/tuna/private/render-support.rkt:61-69`](../../tuna-racket/packages/tuna/private/render-support.rkt)).

**Inference.** Render replacement is sufficient for package-defined application
markup. It is not a safe composition protocol among multiple independent page
contributors, and it lacks an independent invalidation/wake channel.

### 2.6 Module initialization

- **Observed fact.** Current packages perform top-level initialization: the
  counter calls `install-counter-bindings!`; dummy and message define live
  bindings during module instantiation
  ([`packages/tuna-example-counter/main.rkt:1-8`](../../tuna-racket/packages/tuna-example-counter/main.rkt),
  [`packages/tuna-example-dummy/main.rkt:10-32`](../../tuna-racket/packages/tuna-example-dummy/main.rkt),
  [`packages/tuna-example-message/main.rkt:1-23`](../../tuna-racket/packages/tuna-example-message/main.rkt)).
- **Observed fact.** The shared Racket module registry gives once-only module
  initialization; the dummy package records that behavior
  ([`packages/tuna-example-dummy/main.rkt:10-14`](../../tuna-racket/packages/tuna-example-dummy/main.rkt)).

**Inference.** Once-only module initialization prevents accidental repeated
module bodies, but it is not activation lifecycle. It provides no host instance,
registration handle, reactivation, unload, start/stop ordering, or partial
activation rollback.

---

## 3. Capabilities that cannot currently be supplied externally

1. **Observed fact — full command envelope.** No public callback surrounds
   decoded ingress, service reservation, runtime admission, dequeue, user code,
   success/failure, and exact completion. The current path passes private
   profiler observations explicitly (`http.rkt:471-502`,
   `completion-observer.rkt:468-570`, `runtime.rkt:646-770`).

2. **Observed fact — correlation across publication and delivery.** Public state
   snapshots expose revision and state, but not the private provenance used to
   connect one changed root to a later coalesced delivery
   (`runtime.rkt:41-55,376-433,557-572`; `tuna/runtime:3-60`).

3. **Observed fact — snapshot/render/send observation.** The external renderer
   can observe its own render body, but no public seam brackets snapshot
   acquisition or Datastar send/finalization (`http.rkt:389-434`).

4. **Observed fact — independent auxiliary publication.** The state SSE wakes
   only on state invalidation; the profiler has a separate coordinator
   subscription and route (`runtime.rkt:435-546`; `http.rkt:436-444,524-548`).
   A package cannot wake a browser fragment when its own data changes.

5. **Observed fact — page composition.** No public facility adds trusted head
   content, body fragments, Datastar initialization, or another independently
   replaceable selector. The current profiler slots are fixed private strings
   (`http.rkt:322-387`).

6. **Observed fact — HTTP composition.** No public route registration or
   middleware exists (`http.rkt:550-585`).

7. **Observed fact — host-owned extension lifecycle.** No public API registers a
   factory before host creation, starts a package instance with the host, closes
   its ingress, drains it, or joins/diagnoses it during host stop
   (`host.rkt:141-168,224-258`; `completion-observer.rkt:594-680`).

8. **Observed fact — compositional callable interception.** A package can replace
   a live function but cannot register a named around-wrapper that survives a
   later definition and can be removed without erasing that later definition
   (`bindings.rkt:116-123,178-250`).

9. **Observed fact — owned atomic activation.** Configuration is deliberately
   nontransactional. Existing registries do not group route/page/observer/
   lifecycle registrations under one owner or revoke them in reverse order on
   activation failure (`config.rkt:53-64`; ADR 0001 `:18-21`).

**Inference.** A reduced package could wrap the chosen transition and renderer
using only existing APIs, but it would miss admission/queue/send timing, be
bypassed by later renderer or transition replacement, fail to update after a
state-unchanged command, and have no host-owned shutdown. That spike would be
useful evidence of the current ceiling, not successful extraction.

---

## 4. Candidate generic seams, alternatives, and risks

These are proposals to test, not a selected architecture.

### 4.1 Keyed host-extension registration

**Proposal.** Let trusted installed code register one descriptor under a stable
package-owned key. After configuration and ordinary host validation, host
construction snapshots descriptors and creates host-owned instances. Each
successful instance publishes cleanup authority before any interruptible
checkpoint.

**Why generic.** Logging sinks, diagnostics, metrics, protocol bridges, or other
host resources could use the same ownership model; it does not mention profiles,
spans, clocks, or panel selectors.

**Alternatives.**

- Module-import side effects only: smallest, but resources can precede host
  validation and survive configuration failure.
- Host-time descriptor snapshot: matches current serialized startup and avoids
  live activation races.
- Live activation/deactivation of running hosts: most flexible, but introduces a
  new concurrent lifecycle not present today.

**Risks.** Descriptor ordering becomes observable. A flat cleanup stack may not
express dependencies such as “close ingress before runtime drain, finalize after
join.” The seam may need explicit lifecycle stages or dependency ordering, but
stages must describe generic ownership transitions rather than profiler phases.

### 4.2 Owned, generation-checked registration handles

**Proposal.** Registration returns an opaque handle carrying owner and generation
identity. Revocation is idempotent and removes only the generation it owns.

**Why generic.** It prevents stale cleanup from deleting a newer route, observer,
or page contribution and applies to every registry with replacement.

**Alternatives.**

1. reject every duplicate key;
2. make repeated same-owner activation idempotent and reject foreign owners;
3. allow same-owner generation replacement while rejecting foreign owners;
4. allow last-writer replacement with stale cleanup as a no-op;
5. stack and restore prior registrations.

**Risks.** Unconditional removal erases newer work. Stack restoration can
resurrect stale work. Silent idempotence can conceal incompatible activation
options. Existing Tuna precedents disagree: live bindings replace, events reject
duplicates, and logging rejects duplicate initialization but allows repeated
completed shutdown (`bindings.rkt:116-123`; `event.rkt:28-51`;
[`packages/tuna/log.rkt:114-162,215-223`](../../tuna-racket/packages/tuna/log.rkt)).

### 4.3 Advisory command observation with opaque command identity

**Proposal.** Expose narrow advisory callbacks at generic command boundaries:
pre-admission or admission result, dequeue/start, application success/failure,
changed-state publication, and terminal completion. Associate them with an
opaque core command identity or observer-owned token carried privately by core.

**Why generic.** Admission, FIFO execution, exact completion, publication, and
failure are already Tuna core contracts (ADR 0002
[`21-45,63-71`](../../tuna-racket/docs/adr/0002-live-registry-and-owner-runtime-lifecycle.md)). Metrics, tracing,
audit diagnostics, and tests can observe them without knowing state shape.

**Alternatives.**

- Normal notification hooks with no token: simpler but cannot correlate later
  publication/delivery under concurrent ingress and coalescing.
- One observer that receives and returns an opaque token: smaller representation
  but excludes multiple independent observers.
- Multiple keyed observers with core-carried per-observer tokens: composable but
  raises ordering, allocation, failure isolation, and removal questions.
- Around-command middleware: can naturally establish dynamic context but grants
  authority to skip/repeat/change execution unless constrained.

**Risks.** Observer work sits on the serialized command path. Callback latency,
recursion, and failure can compromise liveness. Advisory failures need an
explicit policy and retained diagnostics. Calling a field `provenance` while
retaining the current clock/readiness/span shape would merely rename the
profiler coupling.

### 4.4 Generic publication and delivery observation

**Proposal.** Notify advisory observers when core publishes a changed revision,
then bracket the core-owned state-delivery operations: select latest snapshot,
invoke configured renderer, and send/finalize the serialized fragment. Supply
only generic revision, command identity/token, outcome, and operation status;
observers own clocks and derived data.

**Why generic.** Snapshot, render, and send are transport operations independent
of application state meaning. Revision-based correlation avoids changing the
opaque application state.

**Alternatives.**

- Core carries an opaque token from command to `state-root` and delivery.
- Core emits publication `(command-id, revision)` and the extension keeps a
  bounded revision-to-observation table; delivery reports revision only.
- External code wraps the renderer and HTTP handler. This is broader and more
  ordering-sensitive.

**Risks.** Coalescing means wake revision and delivered revision can differ.
The contract must state which revision is attributed and when correlation can be
discarded. Observer callbacks must not run under runtime/service locks. Exposing
microseconds, inclusive/self time, span nodes, readiness tokens, or omitted-span
counts would expose profiler policy rather than a generic seam.

### 4.5 Generic auxiliary page-fragment contributions

**Proposal.** Permit a host extension to contribute trusted initial head/body
markup and an independently invalidated serialized fragment under a unique
selector/key. Core provides one generic callback-owned SSE multiplex or combines
auxiliary wakes with the existing state stream.

**Why generic.** A status panel, diagnostics surface, or other optional host UI
can publish without becoming part of opaque application state. It avoids a route
per extension and preserves one generic transport contract.

**Alternatives.**

- A fixed generic `/extensions/subscribe` or equivalent multiplexed stream.
- Combine state and auxiliary notifications into `/subscribe`, allowing one
  callback to patch multiple selectors.
- Ordered page-contribution registry plus each extension's own registered route.
- Whole-page renderer replacement. Already possible in part, but independent
  packages conflict and auxiliary updates lack wakes.

**Risks.** Trusted raw markup is authority-bearing. Selector/key conflicts,
ordering, per-client ownership, capacity, backpressure/coalescing, disconnect,
and cleanup need explicit contracts. A “generic” slot fixed to
`#tuna-profiler`, a profiler route, or profiler CSS is not generic.

### 4.6 Route registration or handler middleware

**Proposal.** Keep this as an alternative, not an assumed requirement. If an
experiment proves independent protocols are needed, register exact method/path
handlers under owned keys, with conflict rejection and callback-scoped resource
finalization.

**Why potentially generic.** Optional packages may genuinely need independent
HTTP resources or streams.

**Alternatives.**

- Exact route registry: narrow and conflict-detectable.
- Prefix-mounted sub-handler: gives a package a namespace while limiting global
  interception.
- Whole-handler middleware: maximally general, but ordering and authority are
  difficult to reason about.
- No route registry: use one generic auxiliary stream.

**Risks.** Method precedence, 404/405/`Allow`, decoding limits, safety limits,
trusted response bytes, and shutdown become extension-facing API. A general
router is a large architecture commitment if the profiler is its only user.

### 4.7 Optional callable advice/interception

**Proposal.** If command/delivery hooks cannot cover legitimate composition,
consider named before/after/around wrappers on live callable generations.
Registration identity and ordering must be explicit; removing a wrapper must
reveal the newest underlying definition, not an activation-time snapshot.

**Why potentially generic.** Instrumentation and independent policy wrappers can
compose around any live function.

**Alternative.** Prefer declared command/publication/delivery hooks and avoid a
general advice system.

**Risks.** Around wrappers can skip, repeat, or alter calls; debugging becomes
nonlocal; later redefinition and cleanup are subtle. Capturing `function-ref`
and installing a wrapper now is not sufficient because it freezes the old
implementation and repeated activation can nest wrappers.

### 4.8 Failure and lifecycle policy

**Proposal.** Distinguish advisory observation from authoritative extension work.
Advisory observer faults should not change command results, state publication,
renderer results, or infrastructure failure identity; they should be retained as
inspectable diagnostics. Route/render/page factories remain authoritative at
their normal boundaries unless a separate policy says otherwise.

**Observed fact.** This distinction matches current profiler fail-open behavior
and current completion-observer diagnostic retention (ADR 0002
`:41-45,69-71`). Current cleanup repeatedly attempts all stages and preserves the
first failure (`main.rkt:25-35,43-94`; `host.rkt:181-258`;
`completion-observer.rkt:619-680`).

**Risks.** Treating every extension callback as fail-open hides broken routes and
renderers. Treating advisory observation as fail-closed lets diagnostics change
application semantics. Parallel cleanup changes deterministic failure
precedence.

---

## 5. Generic seams versus disguised profiler APIs

| Candidate | Assessment | Reason |
|---|---|---|
| Host-owned extension descriptor/factory and revocable handle | **Proposal — genuinely generic** | Describes resource ownership and activation, not profiling. |
| Command admission/start/completion observer with opaque identity | **Proposal — genuinely generic if advisory and policy-neutral** | These are existing core command contracts. |
| Changed-revision publication notification | **Proposal — genuinely generic** | Revision publication is core-owned and state-shape independent. |
| Snapshot/render/send operation boundaries | **Proposal — genuinely generic if only operation/status/correlation are exposed** | These are core transport operations. |
| Trusted page contributions and generic auxiliary patch publication | **Proposal — potentially generic** | Useful beyond profiling, but must be validated by another use case. |
| Exact method/path route registration | **Proposal — potentially generic, not yet necessary** | Broad enough for packages, but may exceed extraction needs. |
| General callable advice | **Proposal — generic but high-risk** | General interception, not profiler-specific, yet easy to abuse. |
| `with-span`, `begin-span`, or `end-span` in core with current nesting/status/fault semantics | **Inference — disguised profiler API** | Re-exports the current frontend policy (`profiler-frontend.rkt:9-122`). |
| Detailed snapshot returning profiler ticks and provenance | **Inference — disguised profiler API** | It is exactly current delivery instrumentation (`runtime.rkt:394-433`). |
| Host `#:profiler`, `make-profiler`, or a single “observer extension” slot | **Inference — disguised profiler API** | Encodes current one-profiler ownership rather than open extension composition. |
| Generic lifecycle phases corresponding to `before-profiler-close`/`after-profiler-close` | **Inference — disguised profiler API** | Renames existing profiler test phases (`completion-observer.rkt:179-183,639-648`). |
| Core `#tuna-profiler`, `/profile/subscribe`, profiler CSS slot, or profiler enable value | **Inference — profiler-specific by definition** | These names and policy belong to the optional package. |
| Generic application-state metadata map for profiler records | **Inference — boundary violation** | Makes opaque package-defined state carry core/diagnostic policy and is unnecessary for revision correlation. |
| Static-asset registry created only for current inline CSS | **Inference — unjustified profiler accommodation** | Current profiler owns no separate asset. |

**Proposal — genericity test.** Before accepting a seam, demonstrate at least one
non-profiler observer or auxiliary contribution with materially different data.
If its contract still exposes trees of timed spans, profiler statuses, fixed
selectors, or profiler shutdown order, the seam has failed this test.

---

## 6. One package-level activation form

### Feasibility

**Inference.** Yes: trusted configuration can import a separately installed
collection and invoke one package-owned activation form. No custom loader or
implicit package discovery is required. One form can submit one descriptor that
contains all package contributions and factories.

**Inference.** A mere `require` side effect is insufficient. Racket's once-only
module initialization prevents a module body from rerunning, but does not define
whether the profiler is enabled for a host, how options are changed, what owns
registrations, or how they are cleaned.

### Required semantics to settle

1. **Registration timing.** **Proposal:** registration is allowed during
   serialized configuration; host activation occurs only after configuration
   and ordinary host validation. Decide whether late registration affects only
   future hosts or may mutate a running host.
2. **Atomicity.** **Proposal:** the one activation call either publishes one
   complete descriptor generation or publishes nothing. This does not make the
   whole configuration transactional; earlier successful forms still remain.
3. **Identity.** **Proposal:** the package uses a stable interned key plus an
   owner/generation token. Anonymous registrations should not be required for
   activation.
4. **Duplicate loading.** **Observed fact:** repeated `require` in the shared
   module registry does not rerun module initialization. **Proposal:** repeated
   explicit activation must have a separate documented policy: idempotent for
   identical same-owner options, deterministic replacement, or duplicate error.
5. **Redefinition.** **Proposal:** if same-owner replacement is allowed, new
   hosts see the newest descriptor. A running host either keeps its snapshotted
   instance or follows explicitly live named callbacks; do not imply hot
   instance replacement without a lifecycle contract.
6. **Cleanup.** **Proposal:** successful host activation returns an idempotent
   cleanup authority. Partial activation revokes completed registrations in
   reverse order. Stale cleanup cannot remove a newer generation.
7. **Normal stop.** **Proposal:** extension ingress closes before dependent core
   drain; package-owned subscriptions/threads/resources become terminal and are
   joined; cleanup attempts continue after failures; first-failure precedence is
   deterministic.
8. **Activation failure.** **Proposal:** abort host construction/start before the
   listener is published, clean all already-owned package resources, and retain
   the original activation failure over cleanup failures.
9. **Advisory callback failure.** **Proposal:** contain it from the application
   result and retain a diagnostic. Repeated failure may disable that
   registration only if explicitly chosen; Emacs's automatic removal is not an
   assumed Tuna policy.
10. **Unloading.** **Inference:** package unload is not currently a Tuna or
    Racket configuration contract. Explicit deactivation can be supported
    without promising code unloading. Decide separately whether unload/reload
    is a requirement.

**Inference.** One activation form is most plausible when it registers one
host-extension descriptor, rather than imperatively performing several
unrelated global mutations. That reduces partial-registration states while
preserving Tuna's nontransactional configuration contract.

---

## 7. Route registration and editor-state injection as hypotheses

### Route registration

**Observed fact.** The current profiler needs its hard-coded route because it has
an independent coordinator subscription and sends updates when no application
state publication occurs (`http.rkt:436-444,524-548`).

**Inference.** The route is implementation-specific, not logically necessary.
A generic auxiliary stream can carry package-owned fragments; alternatively the
existing state stream can multiplex state and auxiliary wakes. Either can keep
`/profile/subscribe` out of core and avoid a general route registry.

**Inference.** Route registration becomes necessary only if experiments show
that profiler behavior requires an independent request protocol that cannot be
represented by generic page-fragment publication, or if route composition is
adopted for multiple independently justified packages.

**Proposal.** Compare a generic auxiliary patch source against exact route
registration before committing to router API. Preserve per-connection ownership,
capacity, coalescing, disconnect cleanup, and bounded host stop in either case.

### Editor-state injection

**Observed fact.** Core treats application state as opaque and already permits
configuration to replace the complete root, transition, and renderer
(`application.rkt:116-140`; `render-support.rkt:56-69`).

**Inference.** Profiler records do not belong in editor state. They describe
runtime/transport activity, can change after state publication, and have a
separate lifecycle. Injecting them into the state tree would force unrelated
application transitions and renderers to carry diagnostic policy.

**Inference.** Accurate correlation can instead use an opaque command identity
and published revision, with profiler-owned bounded tables. No generic catch-all
state map is needed.

**Proposal.** Treat any experiment that requires modifying editor/layout/
document/text values merely to display profiler data as evidence that the
transport/observation seam is wrong, not as evidence for a state API.

---

## 8. Selective Emacs primary-source findings

Source inspected: `/home/jay/Code/emacs`, commit
`541f693ca2e8de166cfe52c39bbfc497142215e9`. These findings transfer mechanisms,
not Emacs's editor object model.

### 8.1 Function and value cells

- **Observed fact.** Emacs symbols have distinct function and value storage.
  `symbol-function` reads the function slot; `fset` replaces it and rejects
  cyclic function indirection
  ([`src/data.c:805-930`](/home/jay/Code/emacs/src/data.c)).
- **Observed fact.** `symbol-value` resolves aliases/local/forwarded values and
  `set` writes through the value machinery
  ([`src/data.c:1608-1684`](/home/jay/Code/emacs/src/data.c)).
- **Observed fact.** Higher-level `defalias` records load history/old
  definitions and delegates through `defalias-fset-function`, which advice uses
  to survive later redefinition
  ([`src/data.c:965-1025`](/home/jay/Code/emacs/src/data.c)).

**Inference — transfers.** Tuna already has the useful part: stable separate
callable/value cells and live indirection. The additional transferable lesson is
that wrappers and cleanup must mediate later redefinition coherently.

**Inference — Emacs-specific.** Tuna does not need Emacs Lisp's Lisp-2 symbol
layout, global symbol property lists, buffer-local value representation, or
function-alias representation.

### 8.2 Normal and abnormal hooks

- **Observed fact.** Emacs provides distinct runners: ordered no-argument
  `run-hooks`, argument-bearing `run-hook-with-args`, success/failure
  short-circuit variants, and wrapped execution
  ([`src/eval.c:2876-2990`](/home/jay/Code/emacs/src/eval.c)).
- **Observed fact.** `add-hook` suppresses duplicates, supports deterministic
  depth ordering, and recommends named functions for stable identity;
  `remove-hook` is idempotent and removes ordering metadata
  ([`lisp/subr.el:2311-2478`](/home/jay/Code/emacs/lisp/subr.el)).
- **Observed fact.** Hook execution can combine local and global hook values via
  Emacs's special `t` convention
  ([`src/eval.c:2998-3062`](/home/jay/Code/emacs/src/eval.c)).

**Inference — transfers.** A Tuna hook must explicitly define callback
signature, result aggregation/short-circuiting, order, identity, duplicates,
failure, and removal. Separate hook types are safer than one underspecified
callback list.

**Inference — Emacs-specific.** Buffer-local hooks, the `t` splice sentinel,
and hook naming conventions do not transfer to host-neutral Tuna core.

### 8.3 Advice

- **Observed fact.** Emacs `add-function` composes named/ordered wrappers at a
  function-valued place and replaces an existing matching piece; removal can use
  its name
  ([`lisp/emacs-lisp/nadvice.el:351-419`](/home/jay/Code/emacs/lisp/emacs-lisp/nadvice.el)).
- **Observed fact.** `advice-add` handles undefined/autoloaded functions,
  macros, later definitions, and restoration after final advice removal
  ([`nadvice.el:437-587`](/home/jay/Code/emacs/lisp/emacs-lisp/nadvice.el)).

**Inference — transfers.** If Tuna needs advice, use stable identity, explicit
order, introspection, and a true inverse; later live redefinition must preserve
the wrapper around the newest definition.

**Inference — Emacs-specific or unsuitable.** Macro advice, autoload-pending
properties, symbol plists, and Emacs C/Lisp call-path exceptions should not be
copied. Prefer declared lifecycle hooks to pervasive advice.

### 8.4 Command-loop instrumentation

- **Observed fact.** Emacs records the selected command, runs
  `pre-command-hook`, executes it, runs `post-command-hook`, and then updates
  last-command state
  ([`src/keyboard.c:1485-1585`](/home/jay/Code/emacs/src/keyboard.c)). A newly
  entered loop also runs post-command hooks after commands that escaped with an
  error/quit (`keyboard.c:1318-1355`).
- **Observed fact.** Command-hook execution has special fault containment rather
  than ordinary propagation; failing hooks are reported/quarantined so the hot
  loop can continue
  ([`src/keyboard.c:1893-1999`](/home/jay/Code/emacs/src/keyboard.c)).

**Inference — transfers.** Instrument Tuna at its existing serialized command
boundary, guarantee terminal notification for success/failure, and choose a
specific advisory-failure policy. Bound work on the owner path.

**Inference — Emacs-specific.** Keymaps, buffers, narrowing, redisplay ticks,
undo boundaries, and terminal-local command state are editor semantics and do
not belong in Tuna core.

### 8.5 Package loading and after-load behavior

- **Observed fact.** Emacs separates package installation/activation from actual
  library loading; `require` avoids reloading an already provided feature and
  verifies that loading provided it
  ([`lisp/emacs-lisp/package.el:40-73`](/home/jay/Code/emacs/lisp/emacs-lisp/package.el),
  [`lisp/emacs-lisp/package-activate.el:345-381`](/home/jay/Code/emacs/lisp/emacs-lisp/package-activate.el),
  [`src/fns.c:3779-3882`](/home/jay/Code/emacs/src/fns.c)).
- **Observed fact.** `eval-after-load` runs immediately when already loaded,
  retains registration, and runs again on matching reload. If a feature is
  provided before its file finishes, a one-shot helper waits for the matching
  `after-load-functions` event and removes itself
  ([`lisp/subr.el:6335-6418`](/home/jay/Code/emacs/lisp/subr.el)). General
  after-load callbacks run after file-specific callbacks (`subr.el:6428-6467`).

**Inference — transfers.** Distinguish installed, registered, host-activated,
and instantiated. Specify before/after activation replay, reload behavior,
ordering, failure, and revocation.

**Inference — Emacs-specific.** Do not reproduce `load-path`, filename regular
expressions, generated autoloads, or process-global feature lists. Racket module
identity and Tuna's retained configuration namespace are the native basis.

### 8.6 Registration and cleanup

- **Observed fact.** Emacs's dependable mechanisms are symmetric operations:
  `add-hook`/`remove-hook`, `advice-add`/`advice-remove`, explicit mode
  install/uninstall, and `unwind-protect` for temporary registrations.
- **Observed fact.** `unload-feature` allows a package-specific
  `FEATURE-unload-function`, then attempts standard restoration and heuristic
  hook cleanup. Its source acknowledges that anonymous callbacks and unusual
  state cannot be inferred reliably
  ([`lisp/loadhist.el:233-326`](/home/jay/Code/emacs/lisp/loadhist.el)).

**Inference — transfers.** Tuna should track owned revocable handles and explicit
cleanup. Reverse-order cleanup for partial activation is more reliable than
registry scanning.

**Inference — Emacs-specific or unsuitable.** Heuristic scans of global symbols,
name suffixes, buffers, and load history do not fit Racket modules and cannot
provide deterministic Tuna resource cleanup.

### Emacs boundary conclusion

**Inference.** Emacs supports the case for stable identity, differentiated hook
contracts, compositional but cautious advice, command-boundary instrumentation,
separation of load/activation, and explicit cleanup. It does not justify copying
Emacs symbols, buffer locality, autoloads, feature unloading, editor command
state, or general advice as Tuna architecture.

---

## 9. Unresolved owner decisions

These are product/API decisions, not facts discoverable from the repository.

1. **Behavioral parity.** Must extraction preserve the complete current profile
   — decoded ingress, admission, queue, action/transition, publication,
   snapshot, render, send, status, latest-command replacement, and all existing
   bounds — or may the package initially expose a smaller command profile?
2. **Core compatibility.** Does “zero profiler-specific references” permit any
   deprecated core shim, or must `tuna/profiler`, prelude exports, enable value,
   route, selector, comments, tests, and docs all leave the core package at once?
3. **Package/collection identity.** What separately installed collection owns
   the public activation form and `with-profile-span`?
4. **Activation timing.** Are extensions configured only before host creation,
   or must a running host support activation, deactivation, and replacement?
5. **Duplicate policy.** Should identical repeated activation be idempotent,
   same-owner activation replace, or every duplicate fail?
6. **Multiple observers.** Is one advisory observer sufficient initially, or
   must independent installed observers compose from the start?
7. **Ordering.** If observers/page contributions compose, who chooses order and
   how are equal priorities resolved?
8. **Failure policy.** Where are advisory faults retained and reported? Should a
   repeatedly failing observer be disabled, and if so, who can reactivate it?
9. **Transport.** Prefer one generic auxiliary stream, multiplexing on the state
   stream, exact route registration, or prefix-mounted handlers?
10. **Page authority.** What trusted head/body/raw-markup contributions may an
    installed package register, and how are selector conflicts rejected?
11. **Lifecycle dependencies.** Is staged host-extension lifecycle sufficient,
    or must extensions declare dependencies on core/other extension resources?
12. **Unload promise.** Is explicit deactivate/restart enough, or must Tuna
    support code unload/reload in the retained configuration namespace?
13. **Historical contract handling.** Which accepted ADRs are superseded versus
    retained as historical evidence when the four-package/public-route contract
    changes?

---

## 10. Smallest evidence-building sequence

This is a bounded research sequence, not an implementation plan.

1. **Characterization baseline — no architecture change.** Pin the current
   public and private behaviors from the existing profiler, runtime fault,
   HTTP, SSE lifecycle, and export tests. Add no new semantics. Record which
   assertions are parity requirements versus current implementation detail.

2. **Package-only ceiling experiment — no core changes.** In a temporary or
   test-only separate collection, use only installed-package import, one explicit
   activation call, live value/function definitions, transition wrapping, and
   render replacement. Demonstrate what works: package-owned enablement,
   package-local spans around wrapped code, inline panel rendering, and once-only
   module initialization. Demonstrate what fails: admission/queue/send
   observation, state-unchanged updates, later replacement composition, and
   host-owned cleanup. Do not inject data into editor state and do not add a
   route.

3. **Generic command-observer experiment — private/test-only seam.** Introduce a
   minimal fake observer that records opaque command identities and terminal
   statuses, not spans or clocks. Exercise accepted/full/not-running,
   application success/failure, owner failure, and observer failure. The
   experiment succeeds only if core results/failure identity remain unchanged
   and diagnostics are bounded/inspectable.

4. **Revision correlation experiment — no application-state metadata.** Correlate
   the fake observer with changed-state revision and coalesced delivery using an
   opaque token or bounded revision table. Prove state-unchanged commands,
   multiple ingress requests, wake/delivered revision differences, disconnect,
   and stale correlation cleanup. Reject the experiment if it requires editor
   state changes.

5. **Route-less auxiliary publication experiment.** Publish a non-profiler test
   fragment and a profiler-like fragment through one generic auxiliary patch
   source or a multiplexed state stream. Verify initial page contribution,
   independent wake, selector conflict rejection, coalescing, per-connection
   cleanup, capacity, shutdown, and address reuse. Only if this cannot preserve
   required behavior should the next experiment compare an exact route registry.

6. **Activation/lifecycle experiment.** Exercise one descriptor activation,
   identical repeat, same-owner redefinition, foreign-owner conflict, partial
   activation failure, stale cleanup, repeated cleanup, startup failure, normal
   stop, and cleanup failure precedence. Keep live mutation of a running host out
   unless the owner selects it.

7. **Extraction rehearsal in an isolated package boundary.** Move only profiler
   policy behind the proven generic test seams, remove it from core exports and
   imports in the rehearsal, and run a static vocabulary check plus existing
   core/profiler test partitions. This is where package metadata and ADR impact
   become measurable.

8. **Installed-package proof — separately authorized environment mutation.** In
   a temporary `PLTUSERHOME`, prove core installs and runs without the profiler,
   then install/import/activate the profiler and prove behavior from an unrelated
   current directory. Do not use the normal user package installation. This step
   requires the same explicit authorization as existing clean-install workflows.

**Inference.** Steps 2–5 answer the two largest unknowns before a public API is
chosen: how much existing machinery already suffices, and whether independent
route registration is actually needed.

---

## 11. Implications for a later full core-boundary audit

**Proposal.** A later audit should be broader than checking imports. It should
search for semantic residue in these categories:

1. **Vocabulary:** `profiler`, `profile`, span-tree statuses, profile clocks,
   omitted spans, fixed selectors, and `/profile/subscribe` in production core,
   public exports, default configuration, comments, error text, and active docs.
2. **Representation:** observation fields in command requests, provenance in
   state roots, profiler hints in subscriptions, detailed profiler snapshots,
   and profiler-specific host/service fields.
3. **Control flow:** conditional observed submission, profiler readiness in
   completion ordering, profiler-specific delivery wrappers, and profiler close
   stages.
4. **Web boundary:** profiler slots, data-init code, route/method behavior,
   `patch-profiler!`, and profiler raw-markup composition.
5. **Package topology:** core dependencies and build dependencies, prelude/main
   imports, launcher behavior without the optional package, clean-install order,
   and collection naming.
6. **Tests:** move profiler policy tests to the optional package; retain generic
   observer, registration, lifecycle, route/auxiliary transport, and failure
   tests in core. Asset and process tests should not construct a profiler merely
   to exercise generic handlers.
7. **Documentation/ADRs:** supersede current package topology and profiler-route
   decisions precisely; retain historical ADRs as history rather than silently
   editing their original claims.
8. **Genericity:** validate every new core seam with at least one non-profiler
   implementation and verify no editor/layout/document/text concept entered
   core.
9. **Negative capability:** core must install, compile, start, serve state,
   handle commands, render, publish, and stop when the profiler package is
   absent.
10. **Failure identity and bounded ownership:** advisory package failure must not
    alter authoritative command behavior; all package-owned subscriptions,
    threads, callbacks, and registrations must be bounded and cleaned.

**Inference.** The extraction is likely to expose a small generic host-extension
boundary useful for later audits, but it must not become a catch-all plugin
framework justified by one profiler. Each seam should be accepted independently
against core's existing transport, failure, redefinition, and lifecycle
contracts.

---

## Evidence limits

- **Observed fact.** This investigation was read-only. No Racket tests, package
  installation, server, watcher, or environment mutation was run.
- **Observed fact.** Tuna evidence came from source, tests, accepted ADRs,
  repository documentation, and the indexed code graph. Emacs evidence came
  from the local primary-source checkout at the commit stated above.
- **Inference.** Literal search could miss behavior with no profiler vocabulary,
  though all direct profiler imports and adjacent host/runtime/service/HTTP/
  rendering/state/lifecycle paths were inspected.
- **Inference.** Confidence is high for the current touchpoint and capability
  map, and medium for candidate seam genericity until duplicate, multi-observer,
  activation, compatibility, and transport decisions are resolved by the owner
  and bounded experiments.
