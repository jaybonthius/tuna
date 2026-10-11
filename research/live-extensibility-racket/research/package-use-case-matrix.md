# Tuna package/use-case extensibility matrix

Status: research evidence, not an architecture decision or implementation plan.

## Scope and labels

This report tests general Tuna extensibility needs against current source, tests, product boundaries, Emacs package mechanisms, and plausible packages.

- **Observed** — directly supported by cited source.
- **Derived** — architecture requirement inferred from multiple use cases.
- **Speculative** — plausible package behavior requiring product validation.
- **Severity** — risk of freezing an inadequate core extension boundary, not an existing defect.

## Executive findings

1. **Blocker — the current extension model covers live definitions, not host-owned activation.** Installed packages can initialize once and replace live functions or values, but cannot atomically register related contributions, acquire host-scoped resources, or revoke and clean them deterministically. Configuration is serialized and deliberately nontransactional, with no unload or concurrent load protocol (`tuna-racket/packages/tuna/config.rkt:5-9,53-64`; `tuna-racket/docs/adr/0001-controlled-configuration-trust-and-evaluation.md:13-40`).

2. **Blocker — authoritative interception and advisory observation require different contracts.** Authentication, admission, and scheduling must be able to deny or alter work. Metrics and tracing must not alter application outcomes when they fail. A single profiler-shaped “observer” or universal fail-open hook cannot safely serve both.

3. **High — existing replacement is live but non-compositional.** Callable installation replaces one complete generation, while `function-ref` captures one implementation (`tuna-racket/packages/tuna/bindings.rkt:116-123,178-230`). There is no named advice layer that follows later redefinition and can be removed without erasing newer work.

4. **High — the current web boundary is closed.** Keydown decoding, command ingress, page slots, profiler stream, routes, and assets are hard-coded (`tuna-racket/packages/tuna/private/http.rkt:322-387,417-444,471-585`). Packages cannot add an input source, exact route, mounted protocol, asset, page contribution, or independently invalidated fragment.

5. **High — the current profiler is not a generic precedent.** Profiler-specific observations, provenance, hints, timing, delivery wrapping, host fields, routes, selectors, and lifecycle are embedded throughout core (`docs/tuna/profiler-extraction-research.md:15-58,71-222`). General seams must expose command, publication, delivery, registration, and lifecycle mechanics—not span trees, clocks, profiler statuses, or `/profile/subscribe`.

6. **High — alternate scheduling is constrained by core safety invariants.** Current core promises bounded nonblocking admission, a single sequential owner, first-in/first-out execution, exact completion, publication before completion, accepted-prefix drain, and deterministic shutdown (`tuna-racket/docs/adr/0002-live-registry-and-owner-runtime-lifecycle.md:21-71`). A package may select policy only if core retains those generic safety guarantees or the replacement contract re-establishes them explicitly.

7. **High — editor packages must not drive core state vocabulary.** Core is restricted to opaque state and generic transport, failure, redefinition, and lifecycle. Layouts, document trees, text stores, input semantics, modes, cursors, overlays, persistence, and editor behavior remain package-defined (`AGENTS.md:32-49`; `docs/tuna/research/working-model.md:5-17,57-86`).

8. **Medium — Emacs supports mechanism, not object-model copying.** Its useful patterns are named identity, deterministic ordering, duplicate policy, symmetric removal, advice that survives redefinition, and explicit unload cleanup. Buffer locality, symbol properties, autoload machinery, and heuristic registry scanning are not suitable Tuna defaults (`/home/jay/Code/emacs/lisp/subr.el:2311-2478`; `/home/jay/Code/emacs/lisp/emacs-lisp/nadvice.el:351-419,459-500`; `/home/jay/Code/emacs/lisp/loadhist.el:233-326`).

## Current extension baseline

### Already usable

- Separately installed packages and explicit trusted imports; core does not depend on examples (`tuna-racket/docs/adr/0004-package-topology-and-open-installed-extensions.md:13-26,108-113`).
- Stable live callable/value cells, aliases, actions, transitions, local values, and explicit contexts (`tuna-racket/packages/tuna/bindings.rkt:116-250`; ADR 0002).
- Complete state renderer replacement through `tuna-render-state` (`tuna-racket/packages/tuna/render.rkt:6-18`).
- Configurable initial opaque state and selected keydown transition (`tuna-racket/packages/tuna/application.rkt:114-140`).
- Explicit event objects with named listeners, ordered snapshots, duplicate rejection, and removal (`tuna-racket/packages/tuna/event.rkt:20-80`).
- Example packages prove once-only module initialization, live compiled callers, independent state policy, keymaps, input normalization, and rendering outside core (`tuna-racket/packages/tuna-example-dummy/main.rkt:10-32`; `tuna-racket/packages/tuna-example-counter/private/counter-core.rkt:26-213,215-380`; corresponding package tests).
- Logging demonstrates owned sink creation, ingress closure, drain, join, retryable shutdown, and first-class lifecycle state (`tuna-racket/packages/tuna/log.rkt:103-162,164-191`).

### Missing externally usable capabilities

- Host-scoped extension factories and activation instances.
- Atomic multi-contribution registration and partial-activation rollback.
- Owned, generation-checked revocation handles.
- Authoritative request/command gates.
- Advisory command, publication, rendering, delivery, and lifecycle observation.
- Generic command correlation across admission, execution, publication, and delivery.
- Scheduler/admission strategy selection.
- Input-source and command-source registration.
- Route, protocol mount, asset, page contribution, and auxiliary publication registration.
- Compositional rendering or page contributions.
- Running-host activation/deactivation semantics.
- Public bounded fault-injection seams.

## Operation vocabulary

- **Replace** — select one authoritative implementation or strategy generation.
- **Advise** — wrap or gate an authoritative operation, potentially denying or changing it.
- **Observe** — receive advisory notification without authority to change the result.
- **Register** — add a named contribution to an ordered or keyed registry.
- **Own** — hold package state, threads, ports, subscriptions, caches, credentials, or other resources.
- **Clean** — close ingress, release registrations, drain, join, flush, or resume/fail parked work.

“Running” means an existing host; “in-flight” means accepted work or an active callback; “future” means later commands, requests, connections, renders, or hosts.

## Package/use-case matrix

| Package/use case | Concrete operations required | Running / in-flight / future effect | Abuse and failure risks |
|---|---|---|---|
| **Authentication and authorization policy** — **Speculative; Critical** | **Advise** request admission before route effects; authenticate origin/token/session; **advise** command admission using principal and command metadata; optionally **register** login/callback routes and assets; **own** keys, sessions, revocation state, audit data; **clean** credentials and sessions. | A running policy change should govern future requests immediately. An admitted command should carry a snapshotted authorization decision or principal; retroactive cancellation requires a separate explicit contract. Existing connections may require revalidation on their next operation. | Bypass through an unguarded route/source, confused-deputy behavior, time-of-check/time-of-use races, credential leakage, fail-open defaults, deadlocks while consulting remote policy, and audit data exposing command contents. Current loopback binding is mitigation, not authentication (`application.rkt:119-124`; `README.md:68-74`). |
| **Persistence, autosave, recovery, and application history** — **Speculative; High** | **Observe** successful changed-state publication and terminal command outcomes; **replace** initial-state acquisition with restore; **advise** snapshot/serialization where package codecs are required; **own** journals, snapshots, timers, retention policy, file handles, schema/version metadata; **clean** by flushing or marking incomplete recovery. User undo remains domain policy, not the same log. | Activating on a running host must explicitly seed from the current snapshot; it cannot reconstruct earlier commands. An in-flight command is persisted only if correlation was established before its publication. Future state uses the activated retention policy. | Blocking the state owner, corrupt or partial writes, serialization of capabilities/secrets, restoring incompatible package values, unbounded history, false durability acknowledgements, and conflating rollback, undo, recovery, and external compensation. Those facilities are explicitly distinct in `docs/tuna/research/research-gaps.md:241-263`; encoding/autosave policy remains open at `:383-409`. |
| **Debugger** — **Speculative; Critical** | **Advise** command execution to suspend, step, replace, or abort; **register** debugger commands and UI/protocol contributions; **observe** admission/publication/completion; **own** suspended continuations or cooperative checkpoints, breakpoints, client sessions; **clean** by resuming or terminally failing every parked command. | Future commands can be intercepted after activation. A currently executing command cannot safely become debuggable unless it reaches a declared cooperative checkpoint. Deactivation must never strand the owner or completion. | Deadlock of the sole owner, nested submission, duplicated execution, leaked state/arguments, debugger disconnect leaving work suspended, or changing failure identity. Current nested owner submission is forbidden (`tuna-racket/packages/tuna/private/runtime.rkt:287-327`). |
| **Tracer and profiler** — **Observed profiler, plausible alternate tracers; High** | **Observe** admission result, dequeue/start, application terminal status, changed publication, snapshot/render/send, and lifecycle; optionally **register** an auxiliary inspector fragment; **own** clocks, span/event representation, bounded correlation tables and subscriptions; **clean** observers and streams. Package code may offer its own explicit span form. | Activation observes only boundaries occurring afterward. It cannot invent the start of an already-running command. Terminal notifications should occur for success and failure when a start token exists. Future delivery correlation must account for coalesced revisions. | Observer latency on the serialized path, recursion, unbounded traces, sensitive argument capture, clock faults, correlation leaks, and advisory failures changing application results. Current profiler-specific implementation illustrates these risks but must not define the generic API (`profiler-extraction-research.md:71-222,601-632`). |
| **Alternate admission, scheduling, fairness, and quotas** — **Speculative; Critical** | **Replace** admission and queued-work selection strategies, or **advise** a fixed core safety envelope; **observe** accepted/full/not-running and completion; **own** priority, tenant, quota, deadline, or fairness state; **clean** by deterministically draining, rejecting, or completing all owned queued entries. | Policy changes may apply only to newly admitted work, or may explicitly reorder queued-but-not-current work. The current command should never be silently preempted. Future work follows the selected generation. | Starvation, priority inversion, exceeding bounds, accepted-but-uncompleted work, reordering promises changing silently, queue corruption, duplicate execution, shutdown deadlock, and extension callbacks under structural locks. |
| **New command/input sources** — timers, filesystem events, process output, RPC, IME, accessibility, automation — **Speculative; High** | **Register** a source factory, decoder, source identity, and mapping to actions/transitions; call the bounded canonical submission seam; optionally **register** routes/assets; **own** listener threads, timers, ports, debounce/deduplication state; **clean** source ingress before runtime drain. | A newly activated source affects future messages. An in-flight callback retains its acquired registration generation and must either submit once or terminate cleanly. Deactivation stops new acquisition, then drains callbacks. | Unbounded producers, spoofed source identity, malformed payloads, duplicate retry, feedback loops, source thread leaks, bypassing auth/admission, and embedding browser keydown fields in a supposedly general command contract. Current HTTP accepts only strict keydown requests (`application.rkt:24-112`; `private/http.rkt:471-502`). |
| **Alternative transport, protocol, routes, and assets** — WebSocket, JSON API, RPC, package UI — **Speculative; Critical** | **Replace** the host transport/dispatcher for a complete alternative, or **register** exact method/path routes or prefix-mounted handlers; **register** module-relative assets with content/cache metadata; **own** listeners, connections, streams, capacity tokens; **clean** connections and callbacks within host shutdown bounds. | Route changes affect future requests. An active request/stream should retain its handler generation; removal closes ingress and then its package-owned callbacks. Replacing a listener generally applies to a future host unless an explicit live handoff protocol exists. | Route shadowing, 404/405 precedence changes, unsafe body limits, origin/auth bypass, arbitrary response bytes, selector/path conflicts, cache poisoning, leaked streams, address reuse failure, and broad middleware intercepting core routes. Current route set is a closed conditional (`private/http.rkt:550-585`). |
| **Host UI overlays, panels, and inspectors** — diagnostics, command palette, status, state inspector — **Speculative; High** | **Register** unique trusted head/body contributions and selectors; **register** an independently invalidated auxiliary patch source; **observe** opaque snapshots or generic runtime events; **own** derived panel state, subscriptions and caches; **clean** per-client resources and contributions. | A running browser needs an initial contribution plus later independent patches. In-flight rendering uses a defined contribution snapshot; later generations affect later renders. Removal must remove or blank owned DOM safely. | Cross-site scripting through trusted raw markup, selector collision, CSS/JavaScript interference, leaking opaque application state, runaway invalidation, backpressure, and one package blocking unrelated streams. Current page has fixed profiler-only slots (`private/http.rkt:322-387`). |
| **Application renderers and renderer composition** — **Observed replacement; High for composition** | **Replace** the complete `tuna-render-state` generation; optionally **register** package-specific render providers interpreted by a package-owned dispatcher; **own** caches and projection data; **clean** caches/subscriptions. Core should invoke configured rendering without understanding node types. | Current replacement is live on the next render invocation. An already executing renderer continues with its captured procedure. Architecture must define whether an invalidation queued before replacement uses the old or newest generation when rendering begins. | Trusted-markup injection, inconsistent DOM identity, renderer failure terminating streams, cache staleness, packages overwriting one another’s complete renderer, and a central core type switch. Existing renderer replacement is one complete live function (`render.rkt:11-18`). |
| **Logging, audit sinks, and metrics exporters** — **Partly observed; Medium-High** | **Observe** generic command, publication, delivery, transport, and lifecycle events; **register** named sinks/export endpoints; **own** bounded receivers, files, exporter threads, sampling/aggregation; **clean** by closing ingress, draining, flushing, and joining. Audit sinks may be authoritative only where an explicit compliance policy demands it. | New events use the new sink generation. In-flight operations emit a terminal event only if they acquired an observation token at start. Shutdown drains the accepted event prefix. | Logging secrets, blocking hot paths, recursive logging failures, unbounded queues, silently dropped metrics, exporter shutdown hangs, and metrics failure changing application behavior. Current logging lifecycle is useful evidence (`log.rkt:103-162`) but is process-global and not a general sink registry. |
| **Package manager and live configuration control plane** — **Speculative; Critical** | **Register** installed package descriptors/activation forms; **replace** live definitions and values through existing cells; **own** package installation subprocesses, activation records, namespaces, compatibility checks, and host instances; **clean** registrations and instances explicitly. Code unload must remain separate from deactivation. | Installing a package does not imply activating it. Running-host activation requires an explicit supported protocol; otherwise new descriptors affect future hosts. In-flight work retains a selected generation. Updating installed code cannot assume Racket module initialization reruns. | Trusted arbitrary code execution, dependency confusion, package-install environment mutation, partial upgrades, ABI/API mismatch, stale module instances, deactivation mistaken for code unload, and stale cleanup removing a newer activation. Installation and activation are already distinct in ADR 0004; configuration is trusted and nontransactional (`README.md:27-42`). |
| **Testing, deterministic simulation, and fault injection** — **Observed privately; Critical if exposed** | **Replace** factories or clocks in an explicitly test-scoped host; **advise** named fault points at admission, dequeue, publication, render/send, start/stop; **observe** exact outcomes; **own** barriers, synthetic transports, deadlines and diagnostics; **clean** every barrier and worker even after failure. | Only explicitly opted-in test hosts should be affected. A targeted in-flight operation may pause at a named phase. Removing injection releases or terminally resolves every waiter; future operations are unaffected. | Production denial of service, arbitrary exception injection, orphaned barriers/threads, timing-dependent tests, hidden global state, and fault code bypassing ordinary lifecycle. Current source has private runtime and host fault parameters (`private/runtime.rkt:576-620`; `private/host.rkt:70-85`), not a public package API. |
| **Editor-domain packages** — layout/document trees, text stores, buffers/views if chosen, modes, keymaps, syntax, completion, overlays, file I/O, undo — **Derived boundary; High** | **Own** all domain state and identity; **register** commands, input mappings, node/render interpretations, file/process adapters; **replace** package-selected text/storage or parser strategies; **observe/advise** package-local edits and saves; **clean** files, processes, parsers and domain resources. Core only publishes the resulting opaque root. | Live strategy changes need package-defined state migration; changing a text store or node protocol cannot silently reinterpret existing values. In-flight commands should use one coherent schema/generation or reject a stale result. Future roots use the migrated or newly selected package policy. | Core vocabulary overgrowth, generic catch-all maps, incompatible state migration, stale parser results, text/markup confusion, undo conflated with rollback, and storage absorbing command/mode/render policy. The literal-tree boundary and replaceable storage direction are explicit (`working-model.md:19-82`; `research/README.md:22-37`). |

### Important distinction: two kinds of “overlay”

- A **host UI overlay** is derived diagnostic/presentation material outside opaque application state and may use a generic auxiliary page contribution.
- An **editor overlay** is package-defined domain state with edit mapping, precedence, identity, undo, sharing, and view scope. It must not become a generic core page-overlay facility (`docs/tuna/research/research-gaps.md:212-239,354-381`).

## Cross-cutting architecture demands

These are candidate requirements, not selected APIs.

### 1. Host extension activation and ownership

**Recommended (derived):** test one keyed descriptor per package, snapshotted or activated at host construction, producing a host-owned instance and idempotent cleanup authority.

Required behavior:

- publish cleanup authority before interruptible work;
- either publish one complete descriptor generation or nothing;
- reject foreign key conflicts;
- define identical repeat and same-owner replacement separately;
- revoke partial activation in reverse order;
- make stale cleanup generation-checked;
- close extension ingress before dependent core drain;
- attempt all cleanup and retain deterministic first-failure precedence.

This generalizes current host and logging ownership patterns without naming profiler phases (`private/host.rkt:141-168,181-255`; `main.rkt:37-95`).

### 2. Separate extension contract families

A universal callback registry would hide materially different authority:

1. **Singleton replacement** — renderer, scheduler, transport, initial-state provider.
2. **Authoritative ordered gates/advice** — authentication, authorization, admission, debugger.
3. **Advisory observers** — tracing, metrics, audit notifications.
4. **Keyed contributions** — routes, assets, input sources, commands, page fragments.
5. **Owned services** — persistence writer, exporter, protocol listener, package manager.

Each family needs its own ordering, duplicate, failure, snapshot, removal, and lifecycle policy.

### 3. Owned generation handles

Every registration should have stable owner identity and generation:

- revocation is idempotent;
- stale revocation cannot remove a newer generation;
- replacement does not resurrect an older contribution;
- callbacks already in flight retain a coherent acquired generation;
- later work observes the newest committed generation.

This follows the useful parts of Emacs named hooks/advice while avoiding heuristic unload scanning.

### 4. Generic command and publication correlation

**Recommended (derived):** test opaque command identity or per-observer tokens across:

- attempted admission and its result;
- dequeue/start;
- application success/failure;
- changed-state publication and resulting revision;
- terminal completion;
- optional later snapshot/render/send of that revision.

Core must not expose span nodes, clocks, profiler status vocabulary, or editor-state metadata. Coalesced delivery must distinguish wake revision from the revision actually rendered.

### 5. Explicit activation impact

Every extension operation should declare one of:

- **future-host only**;
- **running host, future operations**;
- **queued but not current work**;
- **active callback generation retained**;
- **cooperative effect on current work**.

“Live configurable” must not imply arbitrary mutation of in-flight work.

### 6. No generic application-state side channel

Package state belongs in:

- the package-defined opaque application value when it is application/domain state; or
- the host extension instance when it is transport, observation, credentials, metrics, persistence machinery, or diagnostic UI state.

A core-owned catch-all extension map would violate the current boundary (`AGENTS.md:44-49`).

## Architecture-level acceptance scenarios

1. **Core-only negative capability:** install, start, submit commands, publish/render state, stream updates, and stop with no profiler or other optional package installed.

2. **Independent composition:** activate an authoritative authentication package and a fail-open metrics package simultaneously. Denied work never enters the runtime; metrics failure does not turn allowed work into failure.

3. **Generation-safe redefinition:** replace a package descriptor or route, then invoke cleanup from the old generation. The new registration remains active and no old implementation is resurrected.

4. **Partial activation failure:** a package registers a command and route, starts a worker, then fails. Host startup does not publish a listener; registrations are revoked, the worker is joined, and the original failure retains precedence.

5. **Command correlation without state change:** observe accepted successful, accepted failing, full, not-running, changed-state, and unchanged-state commands. Every acquired observation reaches one terminal state without application-state metadata.

6. **Coalesced publication and delivery:** commands publish revisions `N+1` and `N+2` before one subscriber wakes. Delivery reports both the wake hint and actual rendered revision without attributing `N+2` to the wrong command.

7. **Scheduler substitution:** a package changes queued selection order while preserving bounded admission, sole state ownership, exact completions, publication-before-completion, and deterministic accepted-prefix shutdown.

8. **Source without HTTP assumptions:** a timer or filesystem package submits a command through canonical admission without constructing keydown fields or registering an HTTP route.

9. **Mounted protocol lifecycle:** a package registers a protocol route, owns two active streams, then deactivates. New requests stop, both streams close independently, host shutdown remains bounded, and the address is reusable.

10. **Auxiliary UI composition:** two unrelated packages publish independently changing fragments. Unique selectors coexist; duplicate selector/key registration fails before page publication; disconnect cleans only the owning connection resources.

11. **Renderer replacement during activity:** a render already executing completes with its acquired generation; the next render uses the replacement. Removing a renderer contribution cannot corrupt another package’s renderer.

12. **Persistence restart:** a package snapshots opaque package-defined state, stops cleanly, restores it into a new host, rejects an incompatible schema, and never requires core to inspect editor or document fields.

13. **Live activation boundary:** demonstrate the chosen rule explicitly—either a running host activates the package for future operations, or activation is rejected/deferred to a future host. No ambiguous partial effect is accepted.

14. **Fault containment:** inject observer failure, authoritative gate failure, renderer failure, cleanup failure, and a break at each ownership transfer. Advisory failure is retained but fail-open; authoritative failure follows its declared contract; no thread, registration, completion, or subscription leaks.

15. **Editor package independence:** configure two materially different literal state trees and renderers, including one without buffers, panes, modes, or text. Core behavior and extension APIs remain unchanged.

16. **Installed-package proof:** from an unrelated current directory and isolated package environment, install core first, install an extension later, explicitly import/activate it, and verify once-only initialization plus live compiled callers. This requires separate authorization because package setup mutates its environment.

## Anti-overfitting tests

1. **Static vocabulary test:** generic core modules and APIs contain no `profiler`, span-tree, profiler clock, omitted-span, `/profile/subscribe`, or fixed profiler selector vocabulary.

2. **Authority contrast test:** the same seam must not force both authentication and metrics into fail-open or fail-closed behavior. If it does, the contract is too profiler-shaped.

3. **Non-timing observer:** implement a metrics counter that observes commands using no clocks, spans, nesting, delivery tree, or profiler statuses.

4. **Non-observer extension:** implement a timer command source to prove host activation is not merely a renamed profiler coordinator slot.

5. **No-route extension:** implement persistence or renderer replacement without requiring an HTTP route registry. Route registration should exist only if independently required.

6. **Route user unlike profiler:** if routes are supported, mount a bounded request/response API or asset package—not another Server-Sent Events panel—to validate methods, conflicts, limits, and cleanup.

7. **Multiple observers:** run audit and metrics observers concurrently with different ordering and failure behavior; neither should receive or mutate another’s private token.

8. **Scheduler without instrumentation:** substitute a deterministic priority scheduler that never renders UI or records spans.

9. **State-unchanged behavior:** observers, metrics, audit, and debugger still receive terminal command events when no state revision changes; persistence need not write a new state revision.

10. **In-flight generation test:** replace each singleton or registration while one callback is active. The active callback remains coherent; future callbacks use the replacement; stale cleanup is harmless.

11. **No catch-all state test:** activate diagnostics, metrics, authentication, and persistence without adding a generic extension map to the opaque application root.

12. **Two unrelated state trees:** use the existing counter root and a structurally different non-editor application. No extension seam may assume buffer, node, cursor, view, text, or layout fields.

13. **Editor storage alternatives:** a package-local reference string store and persistent rope can satisfy the same editor-package contract without exposing representation in core. Historical evidence warns against promoting storage operations into command or rendering policy (`docs/tuna/research/prior-attempts-audit.md:227-267`).

14. **Profiler absence test:** remove the optional profiler package entirely; core tests, package metadata, launcher, routes, page shell, assets, lifecycle, and clean installation still pass.

15. **Cleanup diversity:** test a package with no resources, one thread, multiple streams, a flushable file, and a suspended debugger command. A lifecycle seam that only closes profiler subscriptions is inadequate.

## Evidence-backed candidate validation

### Focused source tests

When implementation exists, repository evidence supports source validation with local collection resolution:

```sh
cd /home/jay/Code/workbench-racket/tuna-racket
PLTCOLLECTS="$PWD/packages:" /home/jay/racket/bin/raco test \
  packages/tuna \
  packages/<new-extension-packages> \
  tests/integration
```

Exact package paths must be derived from the implemented topology. The repository’s accepted source-test pattern is documented at `tuna-racket/docs/adr/0004-package-topology-and-open-installed-extensions.md:118-144`.

### Required new test partitions

- Generic registration/generation/cleanup tests in core.
- Advisory observer correlation and fail-open fault tests in core.
- Authoritative gate and scheduler invariant tests in core.
- Route/asset/page/auxiliary publication lifecycle tests only if those seams are selected.
- Package policy tests in each optional package.
- Core-negative-capability tests with optional packages absent.
- Separately authorized isolated installation tests; never the normal user package environment.

### Static checks

- Public export surfaces contain only intended generic names.
- Core production source has no profiler-specific vocabulary after extraction.
- Core production source has no editor-domain vocabulary introduced by these seams.
- Dependency arrows remain core → generic dependencies and extension → core, never core → optional package.

## Emacs mechanism lessons

Verified against the local GNU Emacs source checkout:

- `add-hook` suppresses duplicates, provides depth ordering, recommends stable named identity, and has symmetric idempotent removal (`lisp/subr.el:2311-2478`).
- Advice can carry names/order and replace an existing matching wrapper (`lisp/emacs-lisp/nadvice.el:351-419`).
- Advice machinery mediates later function definition so wrappers continue around the newest definition (`nadvice.el:459-500`).
- Unloading first offers explicit package cleanup; heuristic global scanning admits it cannot recover anonymous or unusual state reliably (`lisp/loadhist.el:233-326`).

**Derived transfer:** Tuna should use explicit owned registrations and true inverses.

**Do not transfer:** buffer-local hooks, symbol property lists, feature/autoload conventions, package-global unload scans, editor command variables, or Emacs’s object model.

## Residual decisions and research gaps

1. **Blocker:** whether running hosts must support activation/deactivation, or configuration affects only future hosts.
2. **Blocker:** whether alternate scheduling is allowed as a replaceable policy while core retains serialization and bounded safety, or whether FIFO remains fixed core behavior.
3. **High:** exact authority and failure policy for each hook family.
4. **High:** observer and contribution ordering, duplicate keys, and equal-priority behavior.
5. **High:** opaque correlation representation and retention bounds under coalescing.
6. **High:** whole transport replacement versus exact routes versus prefix mounts versus a route-less auxiliary stream.
7. **High:** trusted page contribution authority, selector ownership, and content-security policy.
8. **High:** persistence codec ownership, durability acknowledgement, and schema migration.
9. **High:** authentication threat model beyond the current loopback listener.
10. **Medium:** whether explicit deactivation is sufficient or code/module unload is a product requirement.
11. **Medium:** whether same-owner activation is idempotent, replacing, or rejected.
12. **Medium:** compatibility and Architecture Decision Record supersession policy when profiler code leaves core.

## Confidence

- **High** for current extension, runtime, route, rendering, configuration, package, and profiler-coupling findings; these were verified in direct source and accepted ADRs.
- **High** that authoritative gates, advisory observers, keyed registrations, singleton replacements, and owned services are materially distinct extension families.
- **Medium** for exact candidate seam shape until activation timing, scheduling authority, route strategy, ordering, and failure policies are decided and tested.
- **Medium-low** for plausible debugger, authentication, package-manager, and persistence details; they are intentionally speculative stress cases rather than settled Tuna product behavior.