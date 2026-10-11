# Architecture options for pervasive Tuna live extensibility

This document is an architecture-alternatives synthesis. It is not an implementation plan, a final application programming interface (API) decision, an approval record, or authorization to modify Tuna. It reconciles the research charter, all five live-extensibility reports, the profiler-extraction report, the current Tuna seams, and the completed candidate and hostile-review conclusions supplied for this synthesis.

“Typed family” below means a distinct, explicit protocol with its own authority, ordering, failure, generation, and lifecycle rules. It does not imply that Tuna must adopt Typed Racket.

## 1. Goal, boundaries, and settled constraints

### Goal

Give trusted, separately installed Racket packages pervasive, Racket-native live extensibility over Tuna's **declared observable operation boundaries**, while keeping core small and policy-neutral. A package must be able to activate and deactivate against an already running host, compose with unrelated packages, replace or wrap supported operations, own resources, survive redefinition coherently, and clean up without stale authority damaging a newer generation.

“Pervasive” must not collapse to profiler-only instrumentation. It means that every externally meaningful Tuna operation class is deliberately classified as replaceable, adviceable, gateable, observable, registrable, service-owned, fixed by a core safety invariant, or some explicit combination. It does **not** mean that every private helper, lock manipulation, or arbitrary lexical call is globally interceptable.

### Settled owner constraints

These constraints are inputs, not approval of any API shape:

1. **Clean break.** Compatibility with the current Tuna API, profiler API, package topology, configuration surface, or route/page surface is not required. No migration shim is required.
2. **Trusted in-process packages.** Installed Racket packages and configuration are trusted. Sandboxing and out-of-process isolation are not the design center.
3. **Running-host lifecycle.** Explicit activation and deactivation must work on an already running host. Loading, activation, deactivation, and code unloading remain distinct. A design that only snapshots extensions for future hosts is nonconforming.
4. **Generation rule.** A future call observes the newly committed generation; a call already in flight retains the generation it entered.
5. **Pervasive extensibility.** The program is broader than profiler extraction and must cover declared observable operation classes generically.
6. **Profiler role.** The profiler is a later acceptance case, never the source of route, lifecycle, timing, status, selector, or data-model policy.
7. **Core boundary.** Core owns generic transport, failure, redefinition, publication, and lifecycle mechanics over opaque application state. Packages own state shapes, commands, input semantics, rendering policy, layouts, document trees, text stores, editor behavior, and other domain concepts.

### Highest public acceptance seam

The eventual highest seam is a separately installed package activated through public generic interfaces on a running Tuna host. It composes with an unrelated package, affects later declared operations, is redefined while one call is in flight, and deactivates without stale cleanup harming a newer generation. The in-flight call finishes coherently on its acquired generation; the next call sees the replacement; deactivation reaches a deterministic terminal state with all owned work and resources terminal. Core also starts, accepts commands, publishes and renders opaque state, and stops with every optional package—including the profiler—absent.

## 2. Evidence synthesis

### Observed facts

- Current Tuna already proves stable callable cells with one complete generation, definition-site wrappers that remain live across compiled callers, and explicit snapshotting through `function-ref` (`tuna-racket/packages/tuna/bindings.rkt:54-123,178-230`; `tuna-racket/packages/tuna/prelude.rkt:83-149`).
- Current renderer dispatch captures one live generation immediately before invoking package rendering (`tuna-racket/packages/tuna/render.rkt:6-18`; `tuna-racket/packages/tuna/private/render-support.rkt:61-70`).
- Current events have stable listener identities, ordered snapshots, duplicate rejection, and invocation outside their lock, but one undifferentiated propagation policy and no lifecycle ownership (`tuna-racket/packages/tuna/event.rkt:20-81`).
- Current command runtime has bounded admission, one sequential owner, exact completions, publication before completion, coalesced subscriptions, and deterministic close/drain/join semantics (`tuna-racket/packages/tuna/private/runtime.rkt:267-344,435-572,622-835`; ADR 0002).
- Current host startup and cleanup publish cleanup authority around interruptible boundaries, serialize owners/waiters, attempt every cleanup stage, and retain the first failure, but contain no public running-host extension lifecycle (`tuna-racket/packages/tuna/private/host.rkt:141-168,181-292,323-409`).
- Current HTTP input, route, page, asset, profiler stream, and state stream policy is a fixed private conditional (`tuna-racket/packages/tuna/private/http.rkt:322-387,417-444,471-585`).
- Current configuration shares Tuna's module registry and retains namespaces, but is startup-only and intentionally nontransactional (`tuna-racket/packages/tuna/config.rkt:5-9,53-64`; ADR 0001).
- Installed packages are already the open extension/deployment mechanism, and core-to-optional-package dependency reversal is prohibited (`tuna-racket/docs/adr/0004-package-topology-and-open-installed-extensions.md`).
- Emacs succeeds through multiple mutable indirection families—function cells, advice, hooks, registries, command boundaries, and explicit package cleanup—not through one universal callback mechanism. It cannot safely redefine paths that bypass indirection, macro-expanded or inlined code, captured anonymous closures, or already-owned resources (`research/emacs-extension-architecture.md`).
- Racket's strongest native foundation is an exported lexical stable cell plus a thin macro/assignment-transformer layer. Module redeclaration is possible in restricted circumstances but entangles constants, phases, inspectors, namespace registries, and loading (`research/racket-mechanism-landscape.md`).
- Existing diagnostic measurements place a stable callable-cell read near 8.5 ns on one pinned machine with effectively zero measured allocation, while alias and shared-context paths are much more expensive. These are characterizations, not budgets (`tuna-racket/benchmarks/live-bindings-results.md`; `research/performance-evaluation-program.md`).

### Reconciled independent conclusions

The completed candidate and reviews converge on a hybrid rather than a single mechanism:

1. **Lexical stable cells plus typed hook/gate/registry/service families are the strongest foundation.** The stable object is the pervasive late-bound definition mechanism; family protocols preserve authority and failure distinctions.
2. **Emacs-like advice is viable only at declared Tuna operation boundaries.** It must coexist with, not encode or replace, typed hooks, gates, registries, and services. Arbitrary pervasive advice over every internal function would make authority, failure, and debugging nonlocal.
3. **An extension realm with capability ownership is the strongest lifecycle complement.** Stable cells solve definition liveness; realms solve activation identity, multi-contribution ownership, revocation, drain/join, stale cleanup, and retained lifecycle diagnostics.
4. **Running-host activation and deactivation are already settled requirements.** Future-host-only activation is not an option to select.
5. **Every registry kind needs an explicit acquisition point and terminal point.** “Snapshot semantics” alone is insufficient for requests, asynchronous sources, streams, and owned services.
6. **Profiler behavior cannot select web composition.** Route-less auxiliary publication, exact routes, and prefix mounts must be evaluated with non-profiler cases.
7. **Macro/reflection and running-host lifecycle spikes precede public API selection.** The lexical-cell recommendation remains provisional until compiled callers, arity/keyword reflection, advice/redefinition, and lifecycle races are demonstrated.

## 3. Policy versus mechanism

The architecture should expose a small set of mechanisms while forcing policy to be declared per operation or family.

| Concern | Generic mechanism Tuna may own | Policy that must not be silently baked into the mechanism |
|---|---|---|
| Live definition | Stable lexical identity publishing one immutable generation | Which names are public operations; whether a replacement may change its call protocol |
| Interception | Immutable advice chain attached to a declared operation generation | Whether advice may skip, repeat, transform, catch, or replace; ordering and failure precedence |
| Observation | Typed begin/event/terminal hook protocol with opaque correlation | Which events exist; fail-open retention, quarantine, retry, and data visibility |
| Authority | Typed gate result and declared gate phase | Authentication, authorization, quota, debugger, or scheduling policy |
| Contribution | Immutable keyed or ordered registry snapshot | Keys, conflict rules, matching precedence, priorities, and trusted response/markup authority |
| Ownership | Extension realm, capability handles, acquisition leases, terminal states | Which resources a package creates and how its domain data is migrated or persisted |
| Publication | Atomic generation/root publication and stale-token checks | Application state shape, deltas, schema, render-node meaning, persistence format |
| Lifecycle | Serialized activation/deactivation claims, hidden prepare, commit, close, drain, join, retained failure | Same-owner replacement policy, dependency declarations, time budgets, force/fallback policy |
| Introspection | Detached immutable snapshots with provenance and generation identity | Who may inspect sensitive metadata and how much callback/argument data is retained |
| Web safety | Request bounds, exact ownership, callback-scoped finalization | Which package routes exist, page layout, input schema, selectors, content-security policy |

A capability is primarily an **ownership and authority handle**, not a sandbox boundary. Trusted packages could bypass an API by using arbitrary Racket effects; Tuna capabilities still matter because they make composition, revocation, diagnostics, and lifecycle mechanically checkable.

## 4. Observable operation classes that should be live

“Live” does not always mean “replaceable.” The appropriate live family depends on authority.

| Operation class | Required live behavior | Candidate families | Default acquisition boundary |
|---|---|---|---|
| Named package/core operations | Later calls see redefinition across already compiled callers | Replacement; declared advice; introspection | Entry through the stable operation binding |
| Host extension lifecycle | Activate/deactivate on a running host; observe start/stop; own resources | Realm/service; lifecycle hook; registry | Serialized activation or deactivation claim |
| Transport request dispatch | Later requests see route/mount changes; active request retains selected handler | Registry; gate; declared dispatch advice; hook | After bounded request parsing and route/mount selection, before handler entry |
| Input/message ingress | Add/remove decoders and sources without browser-keydown vocabulary in core | Registry; gate; service; hook | Decoder/source selection or source callback entry |
| Command admission | Later attempts see current auth/quota/admission policy | Gate; advisory hook; possibly replaceable strategy inside a fixed safety envelope | Immediately before the authoritative admission decision |
| Queue selection and command start | Policy changes apply at an explicitly chosen queued-work boundary; current execution is retained | Replacement strategy; gate; hook | Dequeue/selection or command-start boundary, to be decided |
| Application execution | Declared commands can be wrapped or observed; exact result/failure identity remains defined | Declared advice; begin/terminal hook; debugger gate | Immediately before invoking the acquired command generation |
| State publication | Changed roots and command outcomes are observable without inspecting state shape | Advisory hook; gate only if durability policy explicitly requires authority | Publication attempt or successful root commit, separately typed |
| Rendering | Whole renderer remains replaceable; an active render uses one generation | Replacement; declared advice; hook; package-owned provider registry | When rendering actually begins, not when an invalidation is queued |
| Page/auxiliary UI composition | Contributions can appear/disappear live and invalidate independently | Keyed registry; owned auxiliary publication service | Page/render snapshot or auxiliary stream callback acquisition |
| Delivery/serialization/send | Later deliveries see current observers/policy; active send reaches a terminal notification | Hook; limited gate/advice only at a declared transport boundary | Snapshot selection, render, and send are separate declared sub-operations |
| Diagnostics/logging/export | Sinks and observers compose and deactivate deterministically | Hook; keyed registry; service | Event emission or sink queue admission |

### Deliberately not globally interceptable

The following are not automatically declared operations:

- structural registry locks, queue mutations, wake mechanics, completion-cell writes, and cleanup-owner bookkeeping;
- arbitrary private helper calls or package-local lexical helpers that a package has not declared live;
- Racket macro expansions already embedded in compiled clients, compiler inlines, and captured implementation snapshots;
- application-state migration, document semantics, render-node meaning, editor input semantics, or persistence codecs;
- module loading or code unloading.

This boundary preserves pervasive **observable** extensibility without turning Tuna into an evaluator-wide metaobject protocol.

## 5. Contract families

A universal “callback” abstraction is rejected because it hides materially different authority.

| Family | Cardinality and authority | Result/exception behavior | Typical examples |
|---|---|---|---|
| **Replacement** | Exactly one authoritative implementation per operation generation | Defines the operation result and failure; replacement commits a new base generation | Renderer, initial-state provider, selected scheduler strategy, transport strategy |
| **Advice** | Ordered named wrappers around one declared operation; authority is declared per operation | May observe and, only where declared, transform arguments/results, catch, skip, or repeat. The operation contract must state permitted powers | Debugger around command execution; tracing wrapper; test fault point |
| **Hook** | Zero or more advisory callbacks; broadcast or another explicitly named aggregation protocol | Return values are ignored unless the hook type says otherwise. Advisory failure is contained from the authoritative operation and retained diagnostically | Command start/terminal, successful publication, delivery terminal, lifecycle notice |
| **Gate** | Ordered authoritative decisions before an operation | Produces a typed allow/deny/transform result. Failure follows an explicit fail-closed/fail-open/error contract and is never confused with observer failure | Authentication, authorization, quotas, admission, cooperative debugger stop |
| **Registry** | Zero or more contributions, normally keyed and sometimes ordered | Selection/conflict/miss behavior belongs to the registry kind; a selected callback is authoritative for its own operation | Exact routes, prefix mounts, commands, assets, input decoders, page selectors |
| **Service** | Host-scoped owned instance with ingress and terminal lifecycle | Activation returns ownership; deactivation must close ingress, drain/resolve accepted work, release, join, and report retained failures | Input source, persistence writer, exporter, protocol listener, auxiliary publisher |

Additional constraints:

- **Replacement is not advice.** Redefining the base must not accidentally remove advice; replacing the entire operation generation, if supported, must be a separate explicit act.
- **Advice is not a gate.** A gate's deny/allow behavior is typed and locally visible. An around-advice that happens not to call its continuation is too implicit for authentication or admission by default.
- **A hook is not an event-shaped registry.** Hooks need declared correlation, terminality, bounded failure retention, and ownership.
- **A registry is not a lifecycle owner.** Registration removal prevents future selection; an extension realm/service owns active callbacks and resources through terminal completion.
- **A service is not module initialization.** Requiring an installed module may load code once, but activation creates a host-scoped instance and deactivation reaches a host-scoped terminal state.

## 6. Generations, acquisition, and in-flight semantics

### Candidate generation model

The provisional hybrid uses immutable publication units at three scales:

1. **Operation generation:** base implementation, declared call protocol, ordered advice descriptors or precomposed dispatcher, metadata, owner/provenance, and revision.
2. **Registry generation:** immutable key/ordering index containing one selected contribution generation per admitted key.
3. **Host extension generation:** a complete immutable view of committed realm contributions across host-scoped family registries.

The stable cell or host registry root is mutable; its published generation is not. Multi-field state must never be published piecemeal. Writers serialize or use a correct compare-and-set loop; extension code never executes under the publication or registry lock.

An operation acquires one relevant immutable generation at its declared entry. It does not repeatedly consult the latest generation mid-call. A later commit affects later acquisitions. A higher-level request does not automatically pin one host generation for every nested sub-operation: route selection, command execution, render, and send are distinct operations unless an owner decision explicitly requires one end-to-end envelope generation.

Asynchronous work carries its realm and generation identity. A callback that was legitimately acquired before deactivation may finish under that generation. A stale asynchronous result may publish only if its boundary's policy permits completion during drain and its generation/realm token still authorizes publication; otherwise it terminates as stale without mutating newer state.

### Required acquisition and terminal points by kind

| Registry/family kind | Acquisition point | What remains pinned | Terminal point | Deactivation consequence |
|---|---|---|---|---|
| Singleton replacement cell | Immediately before operation body entry | Complete operation generation, including base and metadata | Normal return or arbitrary raise/escape from that invocation | New calls use replacement/absence; acquired invocation completes on old generation |
| Declared advice chain | At outer operation entry, before first wrapper | One composed chain and its base; no mid-chain redefinition | Entire chain unwinds, including terminal finalizers after escape/raise | Removal affects the next acquisition; old chain may not reacquire removed layers recursively unless it starts a new operation |
| Gate registry | Before the authoritative decision begins | Ordered gate snapshot plus input/correlation identity | Typed deny, allow/transform commit, or gate failure | New decisions omit the gate; a decision already entered finishes coherently |
| Advisory hook registry | At each declared notification, or at begin when the hook contract allocates a begin/terminal token | Hook snapshot and any per-observer opaque token | Event callback return; for begin/terminal protocols, delivery of exactly one terminal outcome or explicit abandoned status | No new token acquisition; already acquired tokens must receive their declared terminal event or a documented deactivation terminal |
| Exact route registry | After method/path normalization and matching, before handler entry | Selected handler generation and realm lease | Finite response completion, or streaming callback finalizer after disconnect/stop/failure | Route becomes unselectable first; active callbacks retain ownership until finalization |
| Prefix mount registry | After longest/exact declared mount selection, before sub-handler entry | Selected mount generation and remaining path | Same as route handler | Mount removal cannot reroute the active request through a newer/older mount |
| Input decoder/command registry | After source/schema/key selection, before decoder or command body | Selected contribution and source principal/context | Decoder/command return or failure; asynchronous decoding must own a service lease | New messages cannot select removed contribution; current decode finishes or reports stale according to contract |
| Input-source registry/service | Source factory activation for long-lived source; per-callback entry for emitted work | Realm service instance; callback generation for each emission | Source close/drain/join for service; callback terminal after at-most-once submit/abort | Close source ingress, drain callbacks, then join; canonical gates still apply to submitted work |
| Page/head/body contribution registry | When page or fragment composition takes its immutable snapshot | Contribution set, order, selector ownership | Composition/render return or raise | Later pages omit it; active page assembly remains coherent |
| Auxiliary publication source | Subscription/callback acquisition, with per-update generation selected at update render | Connection-owned subscription plus source generation | Callback finalizer after disconnect/stop/failure | Stop new subscriptions/updates; wake/close and finalize every active subscription |
| Owned service registry | Successful realm commit makes the prepared instance acquirable | Service instance generation and each issued lease | Service ingress closed, all accepted work terminal, resources released, thread/process joined, final diagnostics recorded | Deactivation is incomplete until terminal; stale service handles cannot act on a replacement |

These points are requirements on any eventual API, not selected representation names.

### Queued work remains an owner decision

The charter settles active calls, not every pre-entry queue boundary. Current Tuna resolves a named action or transition after dequeue. The eventual design must say whether a queued-but-not-started command is “future” and acquires the newest generation at dequeue, or whether admission pins command/gate/observer generations. The decision must be explicit per operation class; it cannot emerge accidentally from where a lookup happens to occur.

## 7. Running-host activation, deactivation, and extension realms

### Provisional realm model

Each activation creates an **extension realm** identified by package key, activation generation, host identity, and lifecycle state. A realm owns:

- capability handles for every replacement, advice, gate, hook, registry contribution, and service;
- a hidden activation journal or immutable contribution bundle used for rollback—not a public catch-all application-state map;
- acquired callback/service leases and their terminal conditions;
- explicit resources and cleanup operations;
- a child custodian as abnormal fallback, not normal cleanup;
- bounded retained diagnostics and first-failure state.

A realm does not imply security isolation. Its purpose is exact ownership and revocation.

### Running-host activation candidate

1. Serialize an activation claim against host stop and same-key activation.
2. Create a non-public preparing realm and publish cleanup authority before any interruptible acquisition.
3. Validate the descriptor and prepare contributions/resources without making them selectable. No extension callback runs under host/registry locks.
4. If preparation fails, revoke completed capabilities in reverse acquisition order, close/drain/join prepared services, attempt all cleanup, and retain the original activation failure over cleanup failures.
5. Commit one complete host extension generation that makes the realm's bundle visible to subsequent acquisitions on the **already running host**.
6. Publish the realm as active and expose an opaque deactivation/introspection handle.

Whether preparation may start external ingress before commit is high risk. The default candidate is “no”: resource construction may occur, but package ingress must remain closed until its contribution bundle is committed.

### Running-host deactivation candidate

1. Serialize a deactivation claim; repeated deactivation joins or observes the same terminal result.
2. Commit a new host extension generation that closes acquisition and removes the realm from all future selections atomically enough to prevent partial new use.
3. Close package-owned ingress. Existing acquired calls and callbacks keep their old generation/realm lease.
4. Drain or terminally resolve every acquired callback, stream, queued service item, parked debugger command, and observer token according to its family contract.
5. Revoke registrations/capabilities without restoring shadowed stale generations.
6. Flush/release/join owned resources in the selected dependency order; attempt all stages and retain deterministic first-failure precedence.
7. Use child-custodian shutdown only as a diagnosed fallback after normal cleanup fails or exceeds an owner-approved bound.
8. Publish the realm terminal and release waiters. Code remains loaded unless code unloading is separately selected.

### Lifecycle ordering alternatives inside the realm

- **Reverse ownership stack:** simplest and strongest for partial activation when acquisitions form a strict nesting order. It is insufficient when an observer must close ingress before core drain but remain available for terminal command notifications after that drain.
- **Small generic stages:** for example, close extension ingress, drain core accepted work, finalize extension dependents, then join/release. This fits current Tuna lifecycle evidence but risks freezing today's topology if stages become profiler-shaped.
- **Dependency graph:** expressive for services with true dependencies, but validation, cycle reporting, concurrent mutation, deterministic failure order, and debugging are substantially more complex.

**Provisional preference:** realm ownership plus capability-kind terminal contracts, a reverse stack for rollback, and the smallest proven generic host shutdown partial order. Do not expose a general dependency graph unless lifecycle spikes produce two materially different package cases that cannot be expressed safely otherwise.

## 8. Architecture alternatives

### Option A — lexical stable cells + typed families + extension realms

**Shape.** Export stable operation/value objects through ordinary modules. Thin macros and assignment transformers preserve ordinary lexical call/reference syntax. Each declared operation publishes one immutable generation. Host-scoped typed registries publish immutable roots. Running activation commits a realm-owned contribution bundle; deactivation closes acquisition and drains leases/resources.

**Advice.** Supported only on operations explicitly declared adviceable. Advice lives in the operation generation or a precomposed dispatcher and therefore follows later base redefinition.

**Strengths.** Best support for compiled callers, lexical/module identity, small hot path, coherent redefinition, family-specific authority, introspection, and deterministic lifecycle. It separates global definition liveness from host instance ownership and naturally keeps optional packages pointing toward core.

**Weaknesses.** Macro/reflection design is subtle; host-wide atomic bundle publication across lexical and registry surfaces is not yet proven; lifecycle leases may add hot-path cost; typed families create several small APIs rather than one universal one.

**Hard-to-reverse choices.** Declared callable protocol, advice powers, host extension-generation boundary, registry conflict rules, and lifecycle partial order.

**Assessment.** **Recommended provisionally**, subject to the mandatory macro/reflection, advice, generation, and running-host lifecycle spikes. No concrete API names or exported structs are selected.

### Option B — declared-operation advice spine as the primary dispatch layer

**Shape.** Every declared Tuna operation executes through one common advice/middleware dispatcher. Before/after hooks, gates, observation, replacement, and potentially registry selection are encoded as advice combinators around an operation continuation. Stable cells still hold the dispatcher so compiled callers remain live.

**Strengths.** One mental model; strong Emacs-like flexibility; easy dynamic composition and instrumentation at every declared boundary; extensions can establish continuation marks/context naturally.

**Weaknesses.** A single wrapper protocol blurs advisory versus authoritative failure, makes skip/repeat power easy to grant accidentally, complicates terminal notification and cleanup, and encourages order-dependent packages. Route middleware, auth gates, profiler observation, and lifecycle cleanup would look deceptively similar despite different authority. Around-advice can disrupt tail behavior, keywords, multiple values, exception identity, continuation jumps, and reentrancy.

**Assessment.** Viable only as a **limited layer inside Option A**. It is not acceptable as a replacement for typed gate/hook/registry/service families. Pervasive advice means pervasive coverage of declared operations, not adviceability of every internal function.

### Option C — extension realm/capability table as the primary dispatch foundation

**Shape.** Every host owns one immutable extension-generation table. Operations receive or dynamically consult the current realm/capability environment and dispatch through table entries. Package activation prepares and swaps a new table; deactivation swaps it out and drains owned leases. Ordinary module definitions remain mostly static.

**Strengths.** Strongest atomic host-scoped composition and lifecycle story. A single host generation can expose old or new complete contribution bundles. Introspection and per-host isolation are natural. Multiple hosts can have different extension sets.

**Weaknesses.** Host context must be passed or dynamically selected through nearly every call. Package-level compiled lexical callers outside a host operation are not inherently live. Table lookup on every operation can be slower and less idiomatic than a lexical cell. It risks making all definitions host-global services and conflating per-host policy with package-defined live functions/values. Generic interfaces still need live delegates for existing values.

**Assessment.** Strong lifecycle complement, weak universal definition mechanism. Incorporate its realm and aggregate-generation ideas into Option A rather than selecting it alone.

### Option D — Racket module redeclaration control

**Shape.** Treat mutable module bindings as live locations and redeclare/re-evaluate package modules in a shared namespace/module registry. Already compiled importers are expected to observe updated counterpart variables. Advice and registration state are reconstructed or retained around module replacement.

**Strengths.** Superficially uses native module names as definition identity and could avoid an explicit cell wrapper at some call sites. A module may appear to be the activation/redefinition unit.

**Weaknesses.** Module constants, compiler optimization, inspectors, phases, transformer exports, shared-registry locking, `dynamic-require`, copied exports, and namespace identity all affect behavior. Captured values still remain snapshots. Redeclaration entangles loading with activation and cannot provide deterministic resource deactivation or code unloading. Advice survival and partial failure become module-system problems. It may require globally weakening constant enforcement.

**Assessment.** Retain only as a required control experiment. Reject as the foundation if it requires global constant disabling, fragile namespace manipulation, or cannot preserve runtime and phase-1 identity under bounded serialized loading. Even if the control works, it still needs typed families and extension realms, so it must beat lexical cells materially rather than merely match one case.

### Comparative summary

| Criterion | A. Cells + families + realms | B. Advice spine | C. Realm table first | D. Module redeclaration |
|---|---|---|---|---|
| Compiled lexical callers remain live | Strong | Strong only because it still needs cells/dispatcher | Weak outside host table | Conditional and phase-sensitive |
| Authority distinctions | Strong | Weak | Medium; table kinds still needed | Weak without added families |
| Running-host activation/deactivation | Strong candidate | Advice alone insufficient | Strongest native shape | Loading is confused with activation |
| Atomic multi-contribution host commit | Needs spike | Needs another mechanism | Strong | Fragile/unclear |
| Advice surviving redefinition | Natural in operation generation | Native goal | Requires operation entry kind | Must reconstruct/mediate redeclaration |
| Reflection and call protocol | Needs macro spike | Same plus wrapper complexity | Table entries can be explicit | Compiler/module behavior complex |
| Hot-path outlook | Best live candidate | Linear wrapper depth | Table/realm lookup per operation | Unknown; optimization assumptions weakened |
| Debuggability/introspection | Explicit immutable snapshots | Nonlocal chain | Strong catalog | Namespace reflection-heavy |
| Lifecycle ownership | Realm complements well | Poor alone | Strong | Poor alone |
| Overall | **Provisional recommendation** | Overlay only | Complement only | Control only |

## 9. Introspection requirements

Every public introspection operation should return a detached immutable snapshot and must not execute extension callbacks under registry locks. At minimum, snapshots should make these facts inspectable where applicable:

- declared operation/key and contract family;
- stable identity, current revision/generation, bound/unbound/active/draining/terminal state;
- owning package key, realm generation, host identity, and provenance/source location;
- declared call protocol, adviceability, gate/hook type, and permitted authority;
- ordered active advice/gates/hooks/contributions with stable IDs and deterministic precedence;
- duplicate/conflict policy and selected contribution for a lookup key;
- acquisition count or bounded summary of in-flight work, without exposing mutable lease objects;
- service ingress/drain/join state and retained lifecycle/observer diagnostics;
- stale/revoked handle status;
- prior generation metadata only if bounded retention is explicitly selected.

Introspection should not promise that a changing implementation can report arbitrary changing arity/keywords while preserving one stable procedure identity. It should report the **declared stable protocol** if that direction is selected. Sensitive command arguments, opaque application state, credentials, and package-private tokens must not be retained merely to make inspection convenient.

Continuation marks may describe current operation/realm/advice context for diagnostics, but they are not the authoritative global catalog or lifecycle owner.

## 10. Web, input, runtime, publication, and rendering implications

### Web

The foundation does not select a route architecture. Three materially different web seams remain:

1. **Route-less auxiliary publication:** a generic multiplexed patch source or combined state/auxiliary stream, plus keyed trusted page contributions.
2. **Exact method/path registry:** narrow conflict-detectable routes with callback-scoped ownership.
3. **Prefix mounts:** package-owned subprotocol namespaces, with explicit matching and no global catch-all middleware.

Whole-handler middleware is the highest-authority and hardest-to-debug option and should exist only as advice on a deliberately declared dispatch operation, not as the default router model.

Selection must be driven by non-profiler packages: for example, an input/RPC source for exact routes or prefix mounts, and diagnostics/status UI for auxiliary publication. The current `/profile/subscribe`, profiler selector, latest-command stream, and inline profiler CSS provide no reason to choose a router. Any selected seam must preserve request bounds, method/404/405 precedence, route conflict detection, active-request generation pinning, callback-scoped finalization, disconnect isolation, shutdown, and address reuse.

### Input

Core should not retain a browser-keydown-shaped universal input contract. A generic input-source service may own timers, sockets, filesystem watchers, process output, browser messages, Input Method Editor (IME) composition, accessibility, or automation. A decoder/command registry can map bounded transport messages to package-defined actions. Every source must use canonical admission and authoritative gates; it must not bypass authentication, quotas, capacity, exact completion, or stop semantics. The source realm closes ingress before draining its callbacks.

### Runtime

The current safety envelope—bounded nonblocking admission, one state owner, exact completion, publication before completion, and deterministic accepted-prefix shutdown—is valuable generic behavior. Whether FIFO selection and capacity are fixed or a replaceable strategy is an owner decision. A replaceable scheduler must re-establish the safety envelope and cannot run package callbacks under queue/runtime locks. Current execution is never silently preempted; cooperative debugger checkpoints require explicit operation declarations.

Command correlation should expose opaque identity or per-observer tokens, not profiler trees, clocks, statuses, or application-state metadata. Admission attempt/result, command start, application terminal, successful changed publication, completion, and optional delivery correlation are distinct typed events. State-unchanged commands still receive terminal observation.

### Publication

Core continues to publish one opaque application root and revision. Generic observers may see publication identity and revision, but not domain fields. Coalescing must distinguish the wake hint from the revision actually selected and rendered. An auxiliary source owns a separate publication lifecycle; it does not add a catch-all map to application state.

### Rendering and page composition

Whole-renderer replacement remains a singleton live operation. Independent application render composition should normally be package-owned: a package can install a complete renderer or a dispatcher over its own literal tree values. Core must not add node types or editor concepts.

Host diagnostics and optional panels are a different class from application rendering. If adopted, keyed page/head/body contributions and auxiliary selectors require explicit trusted-markup authority, conflict rejection, immutable composition snapshots, live removal, per-client ownership, and independent invalidation. An editor overlay remains package domain state and is unrelated to a host UI contribution.

### Delivery

Snapshot selection, render, serialization, and send/finalization should be separate declared operation boundaries if evidence requires observing them. Advisory hooks must preserve renderer/send result and infrastructure failure identity. An authoritative delivery gate or advice layer needs separate justification because it can strand streams or suppress state visibility.

## 11. Provisional Racket macro and reflection directions

These sketches show ergonomic directions only. Names, forms, keywords, expansion strategy, contracts, and exports are **provisional** and must not be treated as a selected API.

### Direction 1: declaration-fixed lexical live operation

```racket
;; PROVISIONAL SYNTAX — not an API decision
(define-live-operation (render-state snapshot)
  #:result string?
  #:advice '(observe around)
  #:documentation "Render one opaque snapshot."
  (default-render snapshot))

;; Ordinary compiled call crosses the stable cell.
(render-state snapshot)

;; Explicit base redefinition preserves named advice.
(redefine-live-operation! render-state
  (lambda (snapshot) (package-render snapshot)))
```

The macro could export a stable forwarding closure or procedure-valued struct while retaining a hidden cell. A set!-transformer could make assignment ergonomic, but explicit redefinition may make ownership and intent clearer.

### Direction 2: separate declaration from installation

```racket
;; PROVISIONAL SYNTAX — not an API decision
(declare-live-operation render-state
  #:protocol (snapshot -> string)
  #:advice-authority observe-only)

(define-live-implementation render-state
  (lambda (snapshot) (default-render snapshot)))
```

This makes the stable call protocol and advice powers explicit before implementations change. It may give reflection and syntax errors a clearer basis than inferring protocol from the first body.

### Direction 3: realm-scoped typed contributions

```racket
;; PROVISIONAL SYNTAX — not an API decision
(define-extension tuna-metrics
  (lambda (realm host)
    (realm-observe! realm command-terminal
      #:id 'metrics-command-terminal
      (lambda (token outcome) ...))
    (realm-start-service! realm
      #:id 'metrics-exporter
      #:open exporter-open
      #:close-ingress exporter-close-ingress
      #:drain exporter-drain
      #:join exporter-join)))

;; Must apply to an already running host.
(define activation (activate-extension! host tuna-metrics))
(deactivate-extension! activation)
```

The realm form must not hide arbitrary mutation. Each typed contribution still returns or records a capability with declared acquisition and terminal behavior.

### Direction 4: declared advice with restricted continuation authority

```racket
;; PROVISIONAL SYNTAX — not an API decision
(advise-operation! realm command-execute
  #:id 'debugger
  #:order 20
  #:kind 'around
  (lambda (next command-context)
    ;; Whether next may be skipped or repeated is declared by command-execute,
    ;; not inferred from this wrapper shape.
    (next command-context)))
```

A safer syntax may provide different forms for observation-only wrapping, one-shot around advice, and unrestricted middleware rather than giving every wrapper an arbitrary continuation.

### Mandatory macro/reflection questions

The spike must determine:

- forwarding closure versus procedure-valued struct;
- fixed, dotted/rest, keyword, optional-argument, multiple-value, exception, and tail-call behavior;
- `procedure?`, `object-name`, `procedure-arity`, `procedure-keywords`, contracts, and arity-error behavior before and after compatible/incompatible redefinition;
- higher-order passing of the stable live object versus an explicit implementation snapshot;
- phase-0 and phase-1 exports, assignment transformers, separate compiled clients, and shared module-registry configuration;
- whether self-calls and recursive calls reacquire a generation or remain inside the acquired dispatcher;
- expansion evidence proving that no current implementation or advice chain is copied into compiled client code.

A likely direction is a declaration-fixed call protocol. That is still an owner/API decision after spike evidence, not a conclusion to encode now.

## 12. Performance and concurrency implications

1. **Stable lexical dispatch is the baseline.** The target is one predictable generation read and indirect call, not equality with an inlined direct call. Existing 8.5 ns diagnostic evidence is encouraging but not a portable threshold.
2. **Precompose advice on update paths.** Publishing a generation containing a precomposed immutable dispatcher avoids rebuilding/traversing metadata on each call. Cost should still be measured at advice depths 0, 1, 2, 4, 8, and 16 and across failures, keywords, and multiple values.
3. **Typed hook registries favor immutable vectors.** Dispatch can acquire one vector and invoke outside locks; add/remove pays copy/update cost. Ordering and fault containment dominate micro-optimization.
4. **Exact keyed registries favor immutable lookup roots.** Copy-on-write or cached immutable roots can keep request selection lock-free. Snapshot construction is administrative and may allocate.
5. **Realm lease cost is a major uncertainty.** Counting every synchronous call under a lock would erase much of the cell advantage. Candidate designs should distinguish naturally stack-bounded calls, which pin an immutable generation, from asynchronous/lifecycle-bearing callbacks that require explicit acquired leases. Deterministic deactivation cannot rely on garbage collection.
6. **Aggregate host generations add lookup pressure.** A host table is useful for atomic activation but should not force routine lexical live calls through a global symbol/realm lookup.
7. **Advisory callbacks on the state owner are latency-sensitive.** Fail-open containment does not make a slow observer harmless. Bounded queueing/off-owner service designs may be required, while terminal correlation remains exact.
8. **No callbacks under locks.** This is a correctness gate, not a performance preference.
9. **Ordinary-thread assumptions are bounded.** Existing cell publication relies on Racket 9.2 ordinary coroutine threads. Parallel threads, futures, and places require stronger acquire/release or compare-and-set evidence and are not silently supported.
10. **Performance follows correctness.** Mixed generations, stale revocation, changed authoritative results, lost terminal events, route precedence changes, or lifecycle leaks reject a candidate before timing.

No nanosecond or throughput budget is settled. The owner must set budgets before measurements become pass/fail criteria.

## 13. Fatal risks and rejection gates

A candidate is rejected or returned for owner decision if any of these occur:

1. **Compiled caller staleness:** macro expansion, higher-order passing, generic dispatch, or module import captures the current implementation when live identity was promised.
2. **Reflection incoherence:** a stable callable silently reports an arity/keyword contract that does not match the permitted redefinitions.
3. **Mixed generation:** one call observes base, advice, metadata, or registry entries from different commits.
4. **Stale authority:** an old revocation/deactivation handle removes a newer generation or resurrects a shadowed prior contribution.
5. **Advice escapes its declaration:** wrappers can skip/repeat/transform an operation that was intended to be observation-only, or redefinition drops/duplicates advice.
6. **Callback under structural lock:** extension code executes while a registry, runtime, host, or publication lock is held.
7. **Nonterminal deactivation:** a callback, stream, observer token, accepted service item, parked command, thread, port, process, or waiter remains live after successful deactivation.
8. **Lifecycle deadlock:** stop racing activation/deactivation can strand the sole runtime owner or waiters, or cleanup order prevents terminal command observation.
9. **Partial visibility:** a failed activation exposes only some of its routes/hooks/services or opens external ingress without published cleanup authority.
10. **Advisory authority leak:** observer failure or latency changes command result, publication, renderer result, infrastructure failure identity, or owner liveness.
11. **Web authority overreach:** a package unintentionally shadows core methods/routes, bypasses bounds/gates, owns arbitrary response bytes without declaration, or leaks a streaming callback.
12. **Profiler-shaped core:** generic types or APIs expose spans, clocks, profiler statuses, latest-command policy, `/profile/subscribe`, fixed profiler selectors, or profiler lifecycle phases.
13. **Domain leakage:** core gains editor/tree/text/layout/input-schema policy or a generic application-state extension map.
14. **Redeclaration fragility:** module redeclaration needs global constant disabling, unbounded namespace mutation, phase-dependent special cases, or conflates deactivation with unload.
15. **Unbounded retention:** introspection/correlation keeps commands, opaque state, continuations, prior generations, or diagnostics without an explicit bound.
16. **Performance collapse:** routine no-advice lexical calls require registry locks/name lookup/allocation, or lease/advice costs make the declared pervasive boundaries infeasible under owner-set budgets.

## 14. Exact owner decisions

### Already settled; do not reopen implicitly

- **OD-S1:** clean break; no compatibility or migration requirement.
- **OD-S2:** trusted, installed, in-process Racket packages.
- **OD-S3:** activation and deactivation must mutate an already running host for future acquisitions.
- **OD-S4:** an in-flight call retains its entered generation; later calls see the committed replacement.
- **OD-S5:** pervasive declared-operation extensibility, not profiler-only seams.
- **OD-S6:** profiler is a later generic acceptance case and cannot select route/page/lifecycle policy.
- **OD-S7:** application/editor/input/render-domain policy remains outside core; state remains opaque.

### Must be decided after the prioritized spikes and before public API selection

1. **OD-01 — Stable callable protocol:** declaration-fixed arity/keywords with incompatible redefinition rejected, or deliberately broad reflective behavior with explicit trade-offs?
2. **OD-02 — Advice authority:** which declared operation classes permit observe-only, exactly-once around, skip, repeat, argument transform, result transform, or exception handling?
3. **OD-03 — Definition update operations:** does ordinary base redefinition always preserve advice, and is complete-generation replacement separately exposed?
4. **OD-04 — Queued command acquisition:** acquire command/gate/observer generation at admission, dequeue, or command start?
5. **OD-05 — Ordering and duplicates:** priority representation, equal-priority tie rule, foreign-owner conflict, identical repeat, and same-owner replacement behavior for each family.
6. **OD-06 — Advisory failure policy:** bounded diagnostic retention, retry/quarantine/auto-disable behavior, and reactivation authority.
7. **OD-07 — Gate failure policy:** fail-closed, fail-open, or authoritative error per gate kind; no universal default across security and scheduling.
8. **OD-08 — Activation atomicity:** exact definition of one realm bundle commit across lexical definitions and host registries, including whether externally allocated resources may exist hidden before commit.
9. **OD-09 — Lifecycle dependency model:** reverse stack plus small host partial order, named generic stages, or a dependency graph; required stop/deactivation time bounds and fallback policy.
10. **OD-10 — Same-key running activation:** reject while active, idempotently return the current activation for identical options, or perform generation replacement with old-realm drain?
11. **OD-11 — Runtime policy authority:** retain FIFO/capacity as fixed core policy or permit replaceable scheduling/admission strategies inside the fixed safety envelope?
12. **OD-12 — Web composition:** route-less auxiliary stream, exact routes, prefix mounts, or a justified combination; whole-handler middleware remains separately high-authority.
13. **OD-13 — Page authority:** permitted trusted head/body/raw markup, selector/key ownership, content-security policy, ordering, and independent invalidation bounds.
14. **OD-14 — Correlation:** core opaque command ID versus per-observer tokens, terminal event obligations, publication/delivery retention bounds, and coalesced wake-versus-rendered revision semantics.
15. **OD-15 — Introspection visibility:** public descriptor fields, source/provenance visibility, prior-generation retention, sensitive data exclusions, and diagnostics bounds.
16. **OD-16 — Concurrency scope:** ordinary Racket threads only, or a documented parallel-thread publication and lifecycle guarantee?
17. **OD-17 — Code unloading:** explicit deactivation with code retained, or a separate unload/reload promise? Racket module unloading must not be inferred from deactivation.
18. **OD-18 — Performance budgets:** acceptable no-advice operation overhead, marginal advice/hook cost, registry lookup, owner-path observer cost, activation/deactivation latency, and retained memory.

These decisions are intentionally unresolved here. The provisional recommendation narrows experiments; it does not choose their answers.

## 15. Prioritized spike matrix

All spikes are bounded research/implementation experiments requiring a separately authorized writer. They use deterministic synchronization, no callbacks under locks, explicit worker bounds, and no real server unless separately justified. **P0 macro/reflection and lifecycle results are prerequisites to public API selection.**

| Priority | Spike | Hypothesis | Minimum evidence | Decision consequence |
|---|---|---|---|---|
| **P0-1** | Exported lexical live-operation macro and reflection | A stable exported lexical object can keep separately compiled callers live while preserving a declaration-fixed Racket call protocol | Separate definition/caller modules; direct/higher-order/snapshot calls; set!/explicit redefine alternatives; fixed/rest/dotted/keywords; multiple values; arbitrary raises; tail recursion; expansion inspection; `procedure-arity`, keywords, name, contracts before/after redefine | Success keeps Option A and informs OD-01/03. Failure or broad reflection mismatch requires a revised syntax/representation before any family API; do not fall through to module redeclaration by assumption |
| **P0-2** | Running-host realm activation/deactivation with fake services | A preparing realm can commit atomically to a running host, close acquisition, drain old leases, and become terminal under activation/deactivation/stop races | Activate after host started; partial failure at every acquisition; same-key and foreign conflict; stop racing activation/deactivation; stale cleanup after reactivation; callback already active; two waiters; first-failure identity; no leaked threads/resources | Success validates realm complement and informs OD-08/09/10. Any nonterminal owner, partial visibility, or stale removal rejects the lifecycle shape before API design |
| **P0-3** | Immutable generation and acquisition kernel across family kinds | One immutable operation/registry/host generation yields old-or-new observations and family-specific terminality without callbacks under locks | Replacement, gate, hook token, keyed handler, stream/service lease; concurrent readers/writer; old call + new call; deactivation during each; stale publication/revocation; detached introspection snapshot | Success fixes feasible acquisition model and informs OD-04/08/14/16. Mixed generations or unavoidable per-call locking rejects the representation |
| **P0-4** | Advice/redefinition semantics | Named advice can wrap the newest base, be removed in any order, and obey restricted continuation authority | Two advice layers; base redefine; add/remove/readd; same IDs; failures; keyword/multiple values; self-call/reentrancy; continuation escape/reentry; exactly-once variant; introspection order | Success permits advice overlay and informs OD-02/03/05. If skip/repeat cannot be constrained or removal loses the latest base, retain typed hooks/gates and drop general advice for that operation kind |
| **P1-1** | Module redeclaration control | Module redeclaration can match lexical-cell liveness without global constant weakening or phase/namespace fragility | Compiled importer; mutable runtime export; syntax export and phase-1 state; constants on/off; `dynamic-require`; captured snapshots; advice state; inspector and concurrent loading cases | If fragile, formally reject Option D. If successful, compare performance/ergonomics but still require realms/families; success alone does not select it |
| **P1-2** | Typed hook/gate/registry kernel | Separate families preserve authority and deterministic ordering better than one callback/advice spine | Advisory fail-open hook plus authoritative deny gate; keyed contribution conflict; equal priority; same-owner replacement; stale revoke; immutable snapshots; all callbacks outside locks | Informs OD-05/06/07. If one representation cannot preserve distinctions, keep separate internals rather than unify the public abstraction |
| **P1-3** | Command boundary integration without profiler concepts | Two unrelated observers and one gate can cover command lifecycle without changing core results or liveness | Metrics counter, audit recorder, auth/quota gate; accepted/full/not-running; success/failure; changed/unchanged; owner fault; observer fault; exact terminals; bounded diagnostics | Success justifies generic command boundaries and informs OD-04/06/07/14. Failure narrows/repositions callbacks; never reintroduce profiler observation types |
| **P1-4** | Async stale-publication and service drain | Generation/realm tokens can prevent obsolete async results while allowing legitimately acquired work to terminate | Timer or filesystem-like fake source; deactivate during callback; at-most-once submit; stale result; close ingress; drain/join; activation replacement | Informs service acquisition rules, OD-09/10/14. Failure blocks live source/service registration |
| **P2-1** | Web composition comparison with non-profiler cases | Route-less auxiliary publication and exact/prefix routing have measurably different required authority; the smallest seam can be selected without profiler bias | Diagnostics fragment plus unrelated RPC/input-source package; exact 404/405/Allow/bounds; selector/route conflict; active request generation; stream disconnect; shutdown; no real server initially | Informs OD-12/13. If auxiliary publication handles UI but not RPC, a combination may be justified. Profiler results are excluded from route selection |
| **P2-2** | Render/page composition | Whole renderer replacement and optional host UI contributions can coexist without core node vocabulary | Two unrelated state trees; renderer replace in flight; two page contributions; independent invalidation; selector conflict; trusted markup boundary; no catch-all state map | Informs OD-12/13 and confirms package/core boundary. Any core tree/editor vocabulary rejects the design |
| **P2-3** | Scheduler safety-envelope substitution | A policy package can alter queued selection without violating bounded ownership and completion invariants | Deterministic priority policy; current command retained; queued generation rule; starvation/fairness evidence; publication-before-completion; accepted-prefix shutdown | Informs OD-04/11. Failure keeps scheduler/FIFO core-fixed rather than weakening safety invariants |
| **P3-1** | Correctness-qualified microbenchmarks | Candidates passing behavior gates can meet owner-set overhead budgets with stable scaling | Direct/captured/cell calls; advice depths; hook vectors; registry sizes; realm leases; activation churn; allocation; writer interference; ordinary-thread contention; raw retained results | Informs OD-18 and representation selection. No performance result can rescue a correctness failure; no threshold is inferred before owner budgets |
| **P3-2** | Optional profiler acceptance rehearsal | Profiler policy can live entirely outside core using already selected generic seams | Static zero-profiler core vocabulary; package activation/deactivation on running host; correlation; optional UI; core-only negative capability; non-profiler cases already pass | Validates genericity only after selection. Failure revisits the smallest generic seam, not route/lifecycle design based on profiler internals |

### Spike dependency order

1. P0-1 through P0-4 establish whether the recommended foundation is coherent.
2. P1-1 remains a control; P1-2 through P1-4 establish family and lifecycle behavior.
3. Owner decisions OD-01 through OD-10 and OD-14/16 can then be made with evidence.
4. P2 experiments establish product-facing runtime/web/render choices without profiler overfitting.
5. The owner sets performance budgets; only then run P3-1.
6. Profiler acceptance is last, alongside core-negative-capability and unrelated-package composition.

## 16. Validation and architecture-decision consequences

### Evidence-backed validation direction

Behavior tests should exercise the public and pure integration seams before process tests:

- stable compiled callers, reflection, replacement, advice, hooks, gates, registries, realms, and stale handles;
- running-host activation/deactivation with deterministic fake services and semaphore barriers;
- command, publication, render, and delivery behavior through current pure runtime/HTTP test styles;
- independent installed package composition and core-only negative capability;
- bounded process/SSE/address-reuse tests only after pure lifecycle behavior passes;
- isolated installed-package validation only with separate authorization, never against the normal user package environment.

Repository evidence supports focused commands of the form:

```sh
cd /home/jay/Code/workbench-racket/tuna-racket
PLTCOLLECTS="$PWD/packages:" /home/jay/racket/bin/raco test <focused-existing-or-new-paths>
```

Exact future paths must be derived from the selected topology and implementation; this alternatives document does not invent them. Performance programs run with plain bounded `racket` only after correctness gates and owner budgets.

### Architecture Decision Record impact

A final selection is hard to reverse and warrants one or more new Architecture Decision Records (ADRs). At minimum, accepted decisions would supersede or amend:

- ADR 0002 for the live-definition foundation, generation publication, public operation families, and running-host lifecycle;
- ADR 0004 for package topology/open optional packages if the profiler and other extensions become separate packages;
- ADRs 0003/0005 only to the extent the selected web/page/stream composition changes route or callback ownership.

Historical ADRs should remain intact as history and be explicitly superseded. No ADR is selected or approved by this document.

## 17. Provisional recommendation

Proceed with **Option A: lexical stable cells + typed replacement/advice/hook/gate/registry/service families + host-scoped extension realms/capability ownership** as the leading hypothesis.

The recommendation has four strict qualifications:

1. Advice exists only on declared Tuna operation boundaries and cannot replace typed authority/failure families.
2. Running-host activation/deactivation is mandatory, including old-generation drain and terminal ownership; future-host snapshots alone fail the requirement.
3. Web/input/render seams remain undecided until non-profiler spikes compare route-less auxiliary publication, exact routes, and prefix mounts.
4. No public API, macro syntax, reflection contract, ordering rule, duplicate policy, scheduler authority, lifecycle graph, or performance budget is selected until the prioritized spikes and exact owner decisions are complete.

This hybrid best reconciles Racket's lexical/module strengths, Emacs's multiple live indirection families, Tuna's existing immutable-generation and owner-lifecycle evidence, and the hostile review's acquisition/terminal and anti-profiler constraints without importing Emacs's object model or turning Tuna core into a generic catch-all plugin framework.
