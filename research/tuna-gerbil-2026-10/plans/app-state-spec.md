# Tuna application state, projections and checkpoints

Status: owner-authorized S0–S2 implementation contract, 2026-10-03; the parent manager coordinates exclusive component writers. This document records the audited direction, not an implemented API or passing mechanism proof. S3 is conditional on genuine buffer storage/model implementation. Starting checkout reference: `a49f0ef112d3cb4831ecc16b96b466bb711d4dba`. [Research and provenance](../../research/tuna-app-state/findings.md) distinguish current facts, historical evidence and recommendations. This plan composes with the [structured-buffer proposal](../tuna-buffer-model/spec.md); it does not replace the buffer interface or implement future windows/layouts.

## 1. Goal

Establish the application-state mechanism before building the buffer: commands change authoritative in-memory state, rendering interprets one committed revision, and periodic Scheme-data checkpoints recover current durable data, including unsaved buffer content. The mechanism must permit later buffer/view/layout/mode-state additions without a new store, competing publication clock or native-object persistence format.

`UI = render(committed application state)` means rendering is read-only, consumes explicitly owned values and can be repeated with the same state/definitions. Network delivery may lag; every published projection names the revision it actually represents. The browser never owns another editable document. Immediate-mode rendering and Command Query Responsibility Segregation (CQRS: commands mutate, queries observe) do not require immutable live text storage, a reducer framework or an event log.

### Owner decisions

- In-memory application state is primary; periodically back it up as Scheme data.
- One coherent checkpoint includes unsaved buffer content plus declared durable application data, including navigation/mode choices and eventually layout when implemented. Restoration never writes visited files.
- Undo/redo stays per buffer and is memory-only initially. Restored buffers begin with empty histories; this is not application-global undo.
- Automatically restore a valid compatible checkpoint. Preserve corrupt/incompatible data and stop rather than silently start empty and overwrite it.
- New implementation uses ordinary native Gerbil with `prelude: :gerbil/core`, not Tuna custom macros, live bindings or runtime advice.
- Current scope still displays one buffer, with navigation/focus mirrored across browsers. There is no new session entity, per-browser application state, buffer manager, frame/window system or generic widget shell.

### Approved architectural direction

One application root composes typed, module-owned state models. One existing command owner runs updates and queries. One shared update mechanism prepares/validates all participating changes, applies prepared steps with reversal bookkeeping, and commits one coherent application revision. Render/publication and checkpoint writing follow commit; neither can retroactively undo it. Each model owns its semantic operations and versioned durable representation.

This is an application mechanism, not a universal arbitrary-object store. Extensibility means a new native state model can join the same ownership/update/read/checkpoint protocol. It does not mean unrestricted nested-path setters, interchangeable state engines, actors per object, generic reflection or serializing everything reachable from a root.

## 2. Emacs inspiration and deliberate differences

| Concern | Emacs evidence | Tuna proposal and reason |
|---|---|---|
| State scopes | Buffers, windows, frames and symbols own different mutable data; window point is distinct from buffer text/history. | Preserve explicit model ownership. Future views reference buffer content and may own additional navigation; no copies of text/history or assumption that a browser tab is a view. |
| Mutation | Command-loop ordering is useful but timers/process callbacks can be reentrant; ordinary commands do not universally roll back. | One serialized owner and explicit all-or-nothing in-memory updates, consistent with the stronger buffer proposal. I/O outcomes return through that owner. |
| Display | Redisplay derives output from live resources and modification generations. | Pure revisioned projections; no HTML as authoritative state or full object-graph copying on every key. |
| Recovery | Optional desktop saving preserves selected application metadata; autosave separately protects unsaved text. | A coherent checkpoint contains both current durable metadata and content so positions refer to the recovered content. Explicit file saves remain separate. |
| Undo | Buffer-local history normally lives only in memory. | Same initial ownership/persistence policy; later history codecs remain per buffer. |
| Data format | Desktop loading evaluates generated Emacs Lisp forms; persistence depends on selected variables/mode handlers. | A validated, versioned, data-only format and explicit native codecs. Never execute checkpoint forms or infer classes/imports from them. |

References: [Window Point](https://www.gnu.org/software/emacs/manual/html_node/elisp/Window-Point.html), [Undo](https://www.gnu.org/software/emacs/manual/html_node/elisp/Undo.html), [desktop saving](https://www.gnu.org/software/emacs/manual/html_node/emacs/Saving-Emacs-Sessions.html), [autosaving](https://www.gnu.org/software/emacs/manual/html_node/elisp/Auto_002dSaving.html), and the [primary-source synthesis](../../research/tuna-app-state/findings.md).

## 3. State ownership and future additions

| Value | Owner now / later | Checkpoint treatment |
|---|---|---|
| Application identity and registered model identities | Application root | Durable identities retained; fresh runtime/run identity on every start. |
| Content tree, text sources, properties, persistent annotations, file/coding checkpoints | Buffer model | Encode authoritative durable fields/content, not storage arrays or rich-tree HTML. |
| Current point/mark/selection, semantic focus, restriction and shared logical projection range | Buffer's default navigation | Encode stable source/boundary references and positions; all browsers mirror them now. |
| Undo/redo and retained removed resources | Each buffer | Excluded initially, including unreachable resources retained only by history. |
| Mode choice and durable options | Owning buffer/model; global options only where genuinely global | Store data/qualified names; executable mode/keymap procedures come from installed definitions. No mode framework is built here. |
| Selected buffer/view and layout topology | Application/future layout/view models | Introduce only when implemented; reference resources by identity instead of owning their text. |
| Additional independent point/selection/scroll for future views | Future view navigation | Separate context values referencing buffers; no per-source point and no automatic per-browser state. |
| HTML, logical text views, source maps, measurement/render caches | Derived projection machinery | Rebuild. No second canonical content tree. |
| Diagnostics, pending jobs and user-visible service status | Declared transient model fields / runtime | Recompute or recreate; visible status must be read consistently, not fetched from hidden globals while rendering. |
| Threads, queues, sockets, procedures, execution scopes and update journals | Runtime/implementation | Never serialize. |

The initial production model holds exactly one buffer when the buffer milestone exists. A model catalogue is not a buffer list/switching implementation. Use qualified keys such as `tuna/buffers`; its first schema can contain one buffer, with a later explicit schema migration for multiple buffers. Do not precreate empty layout/view/mode packages to fill future slots.

Each value has one authoritative owner. In particular, the application root does not duplicate `buffer.point`, source characters or buffer history. Default navigation must be represented coherently enough to add an explicit view context later; do not bind ordinary motion to storage fragments, DOM selection or a permanently global cursor. Existing buffer helpers retain default-context behavior; view-aware context extensions require their later scope/API review.

### Demonstrating extensibility now

Use two small native test models to prove a single update can change both, a new model can be registered at startup, old checkpoints can initialize an explicitly optional new model, and versioned data can migrate without serializing classes. These are disposable fixtures, not a fake buffer implementation or production layout system. Adding a model must not require changing the checkpoint envelope, command owner, subscriber protocol or text-store interface.

## 4. Vocabulary, identities and clocks

- `app-state`: opaque application root owning model instances, lifecycle and one update coordinator. It is instance-owned, not a process-global mutable setting.
- `state-model`: a native typed implementation owning a coherent area of application data and its semantic operations. Core buffer/layout/view meanings remain in their implementing modules.
- `model-definition`: startup-registered native factory/schema/codec information keyed by a qualified symbol. A checkpoint contains the key/version/data, not this executable definition.
- `app-read` / `app-update`: scoped capabilities for coherent owner-side reading or staged mutation. Retaining them does not extend their lifetime; off-owner use and continuation re-entry after closure fail.
- `projection`: detached target output with run/revision, renderer version and source-map tags. It is not the full authoritative graph or necessarily a persistent snapshot.
- `checkpoint`: a detached durable-data snapshot plus a versioned on-disk envelope; not a visited-file save, undo record or event journal.
- `resource-ref`: qualified model key, resource kind and durable ID. On restore, model codecs resolve these to fresh live handles. Never persist object addresses, child-index paths or transport IDs as identity.

Use one monotonic exact-integer application revision per running instance. Buffer/source character/property/structure/navigation generations remain local invalidation tokens. They are not a second application commit clock. All models changed by one update become visible at the same application revision; a buffer's own local generation advances only when it changes.

A separate durable generation advances only when the exported durable state changes. Prepared semantic changes declare affected durable fields; do not serialize/hash the entire application on every key merely to detect dirtiness. Transient diagnostic/backup-status updates may require redisplay but do not schedule another backup forever. A successful writer records the exact durable generation it wrote; it cannot declare a newer current state saved. On restore, initialize current/saved durable generation from the validated checkpoint; migration/default additions that change durable data advance it. Checkpoint format version, model schema versions, persistent application identity, live run identity and checkpoint sequence are distinct fields.

Restore retains durable identities, creates fresh live identities/run identity, remaps all valid references and invalidates old browser envelopes, source maps and jobs. Live revision counters may restart under the fresh run identity. Do not reuse a durable ID for another resource in the checkpoint lineage; model schemas declare their allocator/identity rules.

## 5. Required invariants

1. Exactly one serialized owner reads/mutates live authoritative state. Bootstrap construction/restoration is exclusive; binding to the existing input owner transfers authority once before admission. No new mutation thread or command queue is introduced beside the existing lane.
2. Commands, timers, parser/worker outcomes and configuration-driven state changes use that lane. All supported mutators validate owner, lifecycle, update phase and target identity. Trusted native code is not sandboxed; raw/unmanaged side effects are not magically transactional.
3. One shared update is atomic across participating models: precommit failure publishes no partial content, metadata, navigation, history or change. External filesystem/process/network effects are outside this promise.
4. Rendering and export/query callbacks are read-only. They do not allocate live identities, read changing filesystem/time/random data, dispatch writable callbacks or modify model state. Any changing input that affects visible UI is explicit state supplied to rendering.
5. Returned data has detached ownership; opaque live handles are usable only through guarded operations. No returned collection/string or snapshot can mutate authoritative state or another subscriber's private projection.
6. Publication binds revision, output and mapping together before nonblocking subscriber notification. Subscribers can skip intermediate projections but converge on the latest available one.
7. Checkpoint capture runs at a coherent owner boundary; writers receive no live model/store aliases. At most one writer writes a path, with one in-flight and one replaceable latest pending snapshot.
8. Persistent content is not replaced by file references alone. Recovered text, positions, annotations and identities belong to the same captured state.
9. A failed/unknown-version restore does not create an empty replacement checkpoint, start automatic writes or invoke checkpoint-supplied code.
10. A checkpoint does not clear buffer file-modified flags or advance visited-file save checkpoints. Undo does not undo checkpoint writes; checkpoint writing does not undo or redo content.

## 6. Audited application and model interface

This is the complete behavior-facing interface selected for S0–S2, including the trusted model implementation protocol. It is a contract to implement and verify, not a claim that bindings exist. Use native Gerbil with `prelude: :gerbil/core`, explicit exports and the most specific compiler-verifiable parameter/result annotations. Keep representation constructors, raw setters, journal/reversal helpers and physical storage private. No custom Tuna macros, live bindings/advice, procedure-slot model framework or generic object freezer.

Notation: `app` is an opaque `AppState`; `definition` and `model` are native `StateModelDefinition` and `StateModel` interface views implemented by concrete subclasses. `read`/`update` are `AppRead`/`AppUpdate` scoped capabilities. `fn` is an ordinary captured procedure. `PlainData` is the validated checkpoint subset in section 10, not an arbitrary native object graph. Interface signatures check native types; runtime checks establish identity, bounds, phase and schema properties.

Required arguments have no implicit default. `definitions` is an ordered list (default empty); catalogue order is retained for deterministic capture and construction. `renderer:` is required for a stateful instance and has signature `(AppRead) -> ProjectionData`; accompanying `renderer-id:` (qualified symbol) and `renderer-version:` (positive exact integer) are required immutable startup metadata for a supplied renderer, not inferred from a procedure address. A no-model default may retain the existing empty body without a renderer or files. `checkpoint-path:` omitted selects the section-11 path only for an instance with durable production models; explicit `#f` means ephemeral, and tests always pass a scratch path or `#f`. `checkpoint-policy:` omitted selects the validated initial policy in section 6.5. Definition providers must not share live models across app instances.

Live-owner operations never silently marshal to another scheduler. Use submission for cross-thread work. Mutators return void unless specified; ordinary error paths raise native Gerbil errors (closed handles use `Closed`). Expected admission, startup, checkpoint and stop refusals are structured outcomes. No exception-class cancellation framework, asynchronous exception injection or force termination is introduced.

### 6.1 Application lifetime, commands and read side

| Public operation | Inputs/result | Contract / nearest Emacs analogy |
|---|---|---|
| `new-app-state` | `(definitions: [], renderer:, renderer-id:, renderer-version:, checkpoint-path:, checkpoint-policy:) -> AppState` | Construct configuration/catalogue, not live models or a writer thread; no model sharing, global singleton or second owner. |
| `app-start!` | `(app) -> StartupResult` on the existing designated owner | Acquire store authority, restore/default-construct, validate models/references, install first projection, then enable admission. Startup blocked/failure is explicit. Loosely desktop startup, not another command loop. |
| `app-stop!` | `(app, deadline: policy.shutdown-seconds) -> StopResult` from the host controller | A nonnegative finite duration, not a wall-clock timestamp. Close admission, drain at safe boundaries, final capture/flush, release only finished resources; never terminate an applying owner. Repeat calls observe/continue the same stop. |
| `app-info` | `(app) -> AppInfo` | Synchronized detached status: lifecycle/run identity, committed/rendered revisions, model keys/schema versions and persistence status. Safe outside the owner. |
| `app-model` | `(read-or-update,key) -> guarded model handle or #f` | Resolve an explicitly registered model in that capability; not a public raw state/hash getter or buffer manager. |
| `app-submit!` | `(app,fn,mode: 'update) -> AdmissionResult` | `mode` is exactly `update` or `query`; callback is `(AppUpdate) -> owned value` or `(AppRead) -> owned value`. Use the existing lane, not a new app queue. Accepted ticket is not completion/durability. |
| `app-await-command` | `(ticket,timeout: #f) -> CommandOutcome or 'timeout` | All await timeouts are nonnegative finite seconds; `#f` waits without a caller deadline, `0` polls. Repeatable completion; owner's own wait rejected. Timeout does not cancel/replay. |
| `call-with-app-read` | `(app,fn) -> owned value` on owner | `(AppRead) -> owned value`; committed state outside updates, candidate state when nested in preparation. No mutation or retention of capabilities/live resources in the return value. |
| `call-with-app-update` | `(app,fn) -> UpdateResult` on owner | `(AppUpdate) -> owned value`; outer call returns `committed`/`no-op`, nested call `joined` with no final revision. Nested failure poisons the outer update even if caught; all participants roll back. Calls from read/render/apply phases fail. |
| `app-published-projection` | `(app) -> ProjectionResult` | Synchronized status plus detached last-good `Projection` or `#f`; never falsely label stale output current. |
| `new-projection-data` | `(target: symbol, payload: string, map: (), resources: ()) -> ProjectionData` | Public typed renderer construction seam: target/payload required, baseline target `html`. Validate/copy payload and recursively own proper-list PlainData map/resource records; reject live handles/closures/cycles. Empty map/resources valid for small non-buffer rendering. Caller input mutation cannot change the result. |
| `app-refresh-projection!` | `(app) -> ProjectionResult` on owner | Retry/recompute current output after render failure without inventing a content update or advancing durable generation. |
| `app-subscribe!` | `(app) -> SubscriptionResult` | Atomically register subscriber and obtain current projection/status; no missed initial wakeup. |
| `app-await-projection` | `(subscription,timeout: #f) -> ProjectionResult/'timeout/'closed` | Wait for coalesced invalidation then read latest output/status. Initial result comes from subscribe; later status-only failures also wake. Wakeups are not lossless events. |
| `app-unsubscribe!` | `(subscription)` | Idempotent cleanup, safe outside owner; a failed browser/stream cannot stop the owner. |

`app-submit!` update callbacks do not perform external effects inside preparation/apply. Existing no-state commands may retain their resolver behavior. The bridge wraps new ordinary state commands and resolves keyboard intent at execution time. File/process adapters later execute explicit effects outside updates and submit validated outcomes; no general effect framework or persistent command log is required here.

### 6.2 Checkpoints

| Public operation | Inputs/result | Contract / Emacs comparison |
|---|---|---|
| `app-checkpoint-info` | `(app) -> CheckpointInfo` | Configured path/policy, current/saved durable generations, in-flight/pending target, last success/failure and blocked status; no text/private payload in diagnostics. |
| `app-checkpoint!` | `(app) -> CheckpointRequest` on owner | Capture current durable data and request a write; no store/no-op/blocked outcomes explicit. Return accepted ticket plus captured generation, not “saved.” |
| `app-await-checkpoint` | `(ticket,timeout: #f) -> CheckpointOutcome or 'timeout` | Outside-owner repeatable wait. A coalesced ticket succeeds only on synchronized coverage of its generation in this app/store/run; section 6.4 defines failure/closure. |
| `new-checkpoint-policy` | `(enabled?: #t, interval-seconds: 5, retry-seconds: 5, retry-max-seconds: 60, shutdown-seconds: 10, max-bytes: 67108864, max-objects: 1000000, max-depth: 128, max-token-bytes: 8388608) -> CheckpointPolicy` | Validated data-only policy; bounds/units and disabling behavior are in section 6.5. No procedure fields. |
| `app-checkpoint-policy!` | `(app,policy) -> void` on owner | Replace validated scheduling/limits atomically between captures, not mid-read/write. Does not change path/lock, cancel an in-flight write or make durable data dirty. |

Automatic loading is part of `app-start!`, not an unrestricted live `restore!` mutator. A later interactive whole-application revert must define resource disposal, unsaved-state confirmation and stale-input fencing before gaining an interface. Checkpoint reader/writer details and force-overwrite/recovery-file deletion are not public operations in this baseline.

### 6.3 Trusted native state-model protocol

`StateModelDefinition` and `StateModel` are native interfaces, not records of procedure slots. Concrete providers construct definitions with `new-<model>-definition`; there is no generic `make-state-model-definition` accepting factory/decoder captures. Methods below may have thin typed procedure entry points with these names, but do not build a second dispatch layer. Providers cache their native interface view where required by Gerbil conventions. Renderer/command captures remain ordinary procedures, not model methods or a registry framework.

| Operation/protocol method | Inputs/result | Contract |
|---|---|---|
| `state-model-definition-info` | `(definition) -> DefinitionInfo` | Immutable startup declaration; validated once before reading files. |
| `state-model-decode` | `(definition, stored-version, ModelCheckpoint) -> DecodedModelData` | Effect-free validation/migration of body and identity manifests to the definition's current schema; no live resources, I/O or imports. Reject loss of unsupported data. |
| `state-model-create` | `(definition, construction, decoded-or-defaults) -> StateModel` | Factory method: allocate only that model's private resources under exclusive `ModelConstruction`. The distinguished defaults marker is not empty data or `#f`. No cross-model lookup yet. |
| `state-model-link!` | `(model, construction) -> void` | After all models/resources exist, resolve declared references and validate the complete model. Construction-only, not a commit callback; cyclic references may resolve through the private construction resolver. |
| `state-model-close!` | `(model) -> void` | Trusted idempotent resource cleanup after candidate failure or drained shutdown, including partially linked models. Outside updates/commit; cannot save visited files or resurrect state. |
| `state-model-info` | `(model, read) -> ModelInfo` | Guard owner/app/model liveness and capability; detached identity/local-generation summary. |
| `state-model-read` | `(model, read, scope: 'summary) -> owned model-specific read value` | The provider declares supported scopes and their concrete result types; `summary` is required. Range scopes are model-specific, not a generic path query. |
| `state-model-resolve` | `(model, read, resource-kind, durable-id) -> guarded resource handle or #f` | Resolve only this model's declared resources. The handle cannot escape the read/update extent or authorize raw storage access. |
| `state-model-prepare` | `(model, update) -> PreparedModelChange` | Normalize staged semantic work; prepare shared-kernel steps, inverses, local generations/history and durable-change declaration before live mutation. Only touched models participate. |
| `state-model-export` | `(model, read, budget) -> ModelCheckpoint` | Shared capture-owned ExportBudget charges bytes/objects/depth/token size before allocating detached payload. Body/manifests are current-version owned data. Forbidden during an update; no aliases/closures or omitted durable fields. |

`DefinitionInfo` fields: `key` (qualified symbol `namespace/name` with nonempty parts), `schema-version` (positive exact integer), `required?` (boolean, provider default `#t`), `dependencies` (duplicate-free qualified key list, default `()`), `resource-kinds` (duplicate-free symbol list, default `()`), and `supported-versions` (positive exact integer list including current version). Definition metadata cannot change after app construction. Every active model is durable in this initial protocol; transient fields are explicitly excluded by its codec, not a transient-model variant.

Catalogue validation rejects duplicate keys, unavailable declared dependencies and unsupported metadata. Dependencies mean required availability for linking, not construction order or ownership transfer. Cycles are allowed because every candidate allocates before any linking. An absent optional section for a registered definition uses explicit defaults. A missing required section blocks restore. Unsupported versions of known definitions block restore, even when optional; do not replace their data with defaults. Unknown sections restore only when marked optional and preserved opaque as in section 9. A dependency on such an inactive section is unavailable and blocks the dependent model; data cannot add dependencies or weaken a known definition's required rule.

`ModelConstruction` is a private app-bound, startup-only capability. Each factory registers every owned `(kind, durable-id, guarded-handle)` in its app/model-bound construction index before returning. Private typed construction-register/resolve operations validate namespace/kind/ID uniqueness and ownership; they are not public identity allocators. The app calls all factories, checks the complete index against decoded manifests (or explicit-default exports), then calls all link methods through a resolver of `(model-key, kind, durable-id) -> guarded resource or #f`. Resolution does not call a renderer or expose candidates to commands. Factories preserve decoded durable IDs, allocate fresh runtime handles, and do not share mutable resources between models/apps. Each provider owns its `(model-key, kind, durable-id)` namespace and declares/persists allocator high-water or equivalent no-reuse rules. IDs are nonempty Unicode strings, never object addresses, transport IDs or physical paths. References use that complete triple; identical ID strings in different model/kind namespaces are not a collision. Provided identities must match the decoded manifest exactly; dangling/wrong-kind/duplicate ownership fails linking. On failure close constructed candidates in reverse construction order, close capabilities, install nothing and preserve files.

`DecodedModelData` contains `key`, current `schema-version`, owned normalized `data`, `provided`, `references`, and `migrated?`. It is private construction data, not a live model. Decode validates the stored manifests as well as body; migrations may change manifests only under the registered schema's explicit identity policy. `ModelCheckpoint` contains `key`, `schema-version`, `required?`, `provided` as `(kind durable-id)` pairs, `references` as `(model-key kind durable-id)` triples, and `data: PlainData`. `required?` on export comes from the definition, not model mutation. Defaults/export schemas must include allocator state when needed to prevent ID reuse.

Model-specific semantic mutators belong to their native modules, such as the proposed `buffer-type!`, not `app-set-path!`. They join the active common update through the private owner bridge and edit model-local candidates. `PreparedModelChange` is a private typed kernel value: affected model identity, changed/no-op declaration, local summary, durable-changed flag, preallocated reversible steps and commit installs. Native concrete step implementations supply prepared apply/reverse/install behavior, not user-supplied rollback closures. A durable flag is true exactly when the model's exported durable meaning changes, including allocator/default/migration changes; transient changes are false. Normalize equal changes to no-op before declaring flags. Cross-model reference validation uses complete candidates before apply. The kernel owns the journal and phase transitions; providers cannot create their own commit clocks/journals. No arbitrary callbacks, allocation or I/O in apply/reverse/commit. Registration is startup-only; hot package/schema replacement is out of scope.

### 6.4 Returned schemas and outcomes

Schemas below are native detached info/result values with private constructors and no exported setters, except the explicit public new-projection-data renderer seam and validated new-checkpoint-policy configuration seam. Required fields are always present; `#f` denotes unavailable optional identity/value/status data, never a missing record field. Lists default to `()`. Counters are nonnegative exact integers; unbounded application/durable/sequence clocks use generic integer arithmetic. Status/reason/phase categories are named symbol constants. These are not a generic result monad or an event log.

| Value | Fields and exact status contract |
|---|---|
| `AppInfo` | `lifecycle` in `created/starting/running/blocked/stopping/stopped/failed`; `application-id`, `run-id`, `revision`, `projection: ProjectionResult`, `durable-generation`, `models` (DefinitionInfo summaries), `checkpoint: CheckpointInfo`. Before successful startup IDs/counters may be `#f`; blocked instances admit nothing. |
| `StartupResult` | `status` in `defaulted/restored/blocked/failed`; `path`, `format-version`, `migrations` (model key/from/to), `conflicts` (safe identities/reasons, never body text), `run-id`, `revision`, `error`. Only defaulted/restored enables admission after successful first projection. Repeated start on a running app reports the retained successful result, not a second restore/run. No restart after stopped. |
| `AdmissionResult` | `status: accepted/rejected`, `ticket` or `#f`, `reason` or `#f`. Rejections: `not-running/admission-closed/resynchronizing/capacity`. Wrong types/mode/app ownership raise rather than become rejection. HTTP acknowledgement remains bodyless admission, not a ticket response. |
| `CommandTicket` | Opaque app/run identity and monotonically admitted ordering token; private completion storage. Not a durable ID, cancellation API or transport deduplication key. |
| `CommandOutcome` | `status: completed/cancelled/failed`; `mode`, `value` (query value or UpdateResult), `phase`, `committed-revision` or `#f`, `publication: ProjectionResult` or `#f`, `error`. Cancelled means cooperative cancellation before commit, never timeout or uncertain HTTP acknowledgement. Postcommit observer/render errors retain the committed revision/update result. Checkpoint completion is separate. |
| `UpdateResult` | `status: committed/no-op/joined`; owned `value`, `base-revision`, `final-revision`, `changed-models`, `changes` (provider-owned summaries), `base-durable-generation`, `final-durable-generation`. Committed increments revision once and durable generation once iff any durable flag; no-op leaves both equal and change lists empty. Joined has `final-revision/final-durable-generation: #f` and empty final change lists; it reports only callback completion, never an independent commit. Nested exceptions/nonlocal escape poison the outer candidate even if caught. |
| `ProjectionData` / `Projection` | Renderer uses new-projection-data for `target` (symbol), `payload` (string), `map` (proper list of target-adapter PlainData records, default `()`), `resources` (proper list of `(model-key kind durable-id local-generations)` records, default `()`; local generations are proper two-element `(name generation)` records with symbol names/nonnegative exact integers). Real buffer mapping records belong to its later HTML adapter schema, not a fabricated S0–S2 map. App adds `run-id`, actual `revision`, immutable `renderer-id/renderer-version`. No live model/resource/capability handles. Baseline HTML payload is escaped by renderer; constructor does not reinterpret it as model text or escape already-rendered markup. No mandatory full model snapshot. |
| `ProjectionResult` | `status: current/stale/unavailable`, `projection` or `#f`, `current-revision`, `error` or `#f`. Stale contains last-good output tagged with its actual older revision; unavailable has no output. Current can still report a failed retry of the same revision without relabeling the good projection. Refresh does not advance clocks. First-render failure is startup failed, not running with an invented empty successful projection. |
| `SubscriptionResult` | `status: subscribed/closed`, `subscription` or `#f`, coherent initial `projection: ProjectionResult`. Before running or after admission/subscription closure returns closed. Each subscription has one latest-status notification slot; a slow stream cannot block the owner. Unsubscribe is idempotent. |
| `CheckpointInfo` | `status: no-store/ready/blocked/closing/closed`; `path`, `policy`, `current-generation`, `saved-generation`, `sequence`, `in-flight-generation`, `pending-generation`, `last-outcome`, `retry-seconds` or `#f`, `blocked-reason` or `#f`. No-store has no writer/lock; counters unavailable before startup are `#f`. Pausing scheduling does not mean clean or release the lock. |
| `CheckpointRequest` | `status: accepted/no-op/disabled/blocked`; `ticket`, `target-generation`, `reason`, `error`. Accepted means a coherent snapshot was captured or the current generation already has an in-flight/pending capture; no-op means synchronized saved coverage exists and has no new ticket. No-store or policy disabled gives disabled. Capture/validation failure is blocked for this request with an error, without claiming a disk write. |
| `CheckpointTicket` / `CheckpointOutcome` | Opaque app/store/run/target ticket. Outcome fields: `status: written/failed/closed`, `target-generation`, `written-generation`, `sequence`, `phase`, `replacement: not-replaced/replaced`, `synchronization: complete/uncertain/not-attempted`, `error`, `cleanup` (safe metadata). Written requires complete file/parent sync and covers target. A newer same-run snapshot can cover a superseded pending ticket; superseding alone is not success/failure. A failed attempt completes tickets assigned to that attempt as failed; retained latest data retries automatically with new attempt tracking, never rewriting a retained failed outcome. Pending tickets remain pending until their covering attempt or closure. Closed means no successful coverage before writer closure. |
| `StopResult` | `status: stopped/pending/failed`, `admission-closed?`, `owner-drained?`, `checkpoint` (outcome, disabled/no-op or timeout), `uncheckpointed-generation` or `#f`, `released` (resource names), `error`. Pending means the deadline expired with live owned work; retain app/writer/store ownership. Failed may have fully released resources but failed durability, and includes an actionable warning. Stopped is clean cooperative completion; ephemeral/disabled instances explicitly make no durability promise. |
| `ModelInfo` | `key`, `schema-version`, app-bound live `identity`, `local-generations` (named exact integer pairs), `resource-kinds`. No underlying stores, journals or callback captures. |
| Error diagnostics | `operation`, phase in `admission/read/prepare/apply/commit/render/capture/decode/link/open/read-file/encode/write/flush/sync/replace/directory-sync/close`, safe `model/resource`, `committed?`, native `cause`, safe reason/recovery guidance. Keep native exceptions intact unless concrete translation is needed; never dump payload/captures into logs. |

Query/update callback results must already satisfy their module's detached ownership contract: scalars, detached native read/result values and recursively owned data, not arbitrary live objects copied by reflection. The core does not promise to freeze a closure or unknown extension graph. Live handles returned by lookup/resolve are usable only within the capability; returning them from the callback is a contract violation. Tests prove nested string/list isolation on supported returned schemas.

Export inventory: the named operations in 6.1–6.3, the native StateModel/StateModelDefinition interfaces needed by providers, and read-only predicates/accessors for the above named public info/result/policy types and their listed fields. Ticket/subscription/app handles export predicates only, not representation constructors/accessors. `new-checkpoint-policy` is the sole public policy constructor; `new-projection-data` is the public renderer-result constructor. Concrete definition constructors belong to provider modules, not a generic core factory. Construction capabilities, defaults marker, ExportBudget, DecodedModelData, PreparedModelChange/steps and their constructors are private inter-module protocol, not facade exports. Model-specific read values/export codecs belong to their provider. No generated setters or unchecked/private entry points leak through the facade; no additional convenience exports without an inventory revision.

### 6.5 Selected defaults and bounded data

The manager approved these initial configurable values for implementation. They remain reviewable settings, not latency/loss/performance promises. No data file configures executable callbacks or changes its own limits.

| Policy field | Initial value | Validation/meaning |
|---|---|---|
| `enabled?` | `#t` for stateful instances | Boolean; explicit ephemeral path `#f` and the production no-model default create no store regardless. Disabling pauses new requests/automatic writes, does not cancel accepted work. Startup still validates/restores an existing configured store. |
| `interval-seconds` | `5` | Positive finite seconds; dirty wall-clock check, not idle debounce. |
| `retry-seconds`, `retry-max-seconds` | `5`, `60` | Positive finite seconds; failed attempts use doubling backoff capped at max, max >= initial. A successful write resets retry delay. |
| `shutdown-seconds` | `10` | Nonnegative finite seconds; cooperative total wait budget, not permission to terminate. |
| `max-bytes` | `67108864` (64 MiB) | Positive exact fixnum; UTF-8 bytes for whole input/output including syntax/comments. Applies to read, capture/encode and retained opaque sections. |
| `max-objects` | `1000000` | Positive exact fixnum; count each list pair and each scalar occurrence; no sharing notation. Envelope/manifests/opaque data count too. |
| `max-depth` | `128` | Positive exact fixnum <= max-objects; scalar depth 0, proper list depth 1 + maximum element depth (empty list depth 1). Long flat lists consume object budget, not nesting per cdr. |
| `max-token-bytes` | `8388608` (8 MiB) | Positive exact fixnum <= max-bytes; byte length of one source lexeme, including escapes/quotes for strings/symbols. Also bounds a single large text value; larger documents/values require explicitly validated overrides. |

Configuration is validated before startup/policy replacement; no negative/nonfinite/fractional budget or implicit unlimited sentinel. Larger overrides remain subject to native fixnum bounds and the same enforcement. Check byte/token/depth/object capacity before unbounded read allocation, and during capture before materializing oversized detached output; enforce again after codecs/migrations. A capture shares one private ExportBudget across model exports and opaque sections, so many individually small sections cannot exceed the aggregate allowance before rejection. Trusted providers use its typed preallocation charging operations and never copy an oversized source first and check later; the final encoder checks actual emitted bytes too. Budget accounting is part of the restricted reader/encoder, not a post-hoc recursive walk of arbitrarily large native `read` output. The closed reader may use standard native I/O plus a checkpoint-specific bounded parser; native readtable flags alone do not establish budget enforcement. Tests at/over each limit and hostile syntax are mandatory; this document does not claim streaming enforcement is already proved.

One in-flight plus one latest pending snapshot bounds snapshot count, not total model memory or ticket count. Size and retained-ticket/backpressure measurements remain acceptance evidence; do not add a new input-dropping policy to satisfy memory tests. A validated policy reduction can make the next capture/restore fail explicitly; it cannot silently truncate data or cancel a write already accepted under the old limits.

## 7. Update composition with the buffer

The application coordinator is the common transaction host. Do not implement `call-with-app-update` as “call an already committed buffer update, then edit app metadata.” That cannot undo a later metadata/validation failure and creates competing publication/rollback systems.

An attached buffer's private update bridge delegates to the same host while retaining buffer-specific edit normalization, read-only checks, anchors/properties, structure validation, compound history and no-op semantics. `call-with-buffer-update` limits semantic scope to that buffer but joins the current application update. Direct supported buffer operations on the owner open an implicit common update when none exists. Standalone buffer tests use the same update kernel with one participant, not a separate transaction engine.

The shared sequence is:

1. Enter `preparing`; create an update token and model-local candidates. Nested reads/mutations see candidate data without publishing it; staged cross-model references need not be globally valid until final preparation. Full rendering/checkpoint capture is forbidden inside an open update.
2. Validate complete changes/references, invoke allowed preparation callbacks, normalize source edits and prepare capacity, inverses, roots, local generations/history and journal slots.
3. Enter `applying`; execute trusted prepared primitives and record reversible effects in the preallocated shared journal. No rendering, user observers, I/O or unprepared allocation/callbacks in this extent.
4. On precommit exception/cancellation/nonlocal escape, reverse populated steps newest-first without fresh validation/allocation/callbacks; discard candidates/history and close the token.
5. Commit candidate roots, local generations, buffer history and one application revision in a callback-free extent. No-op content/state produces no revision. Navigation-only state may advance application/durable generation without content undo.
6. Render/publish/notify and schedule eligible checkpoint capture after commit. Rendering/writing/after-change errors report a committed outcome; never reverse it. Close capabilities and reject continuation re-entry.

A render failure leaves committed state intact. Retain only correctly tagged last-good output, expose unavailable/stale status, and allow a fresh full projection. Do not report rendered completion or resume a browser's resynchronization fence until its required projection exists. Runtime/controller code must have a safe diagnostic path when ordinary rendering fails.

Atomic update and user undo are different. One update may touch future layout plus buffer content; buffer undo still concerns its own semantic history. There is no `app-undo!` or automatic inverse of filesystem/process effects. A future user-facing cross-model undo command needs its own contract.

This refines the buffer proposal's private ownership/update/publication responsibilities, not its public operation names. The companion buffer plan's sections 3/13/14/17 now align with this host; its remaining buffer-specific schema audit precedes S3. Preserve its source-local generations, mirrored navigation, target-neutral rendering and file-save distinctions. Do not duplicate buffer text/anchors in the application root.

## 8. Projection and publication pipeline

Render on the owner from committed resources, using the existing target-neutral buffer/render-context seam when available. Renderer definitions are ordinary captured procedures registered at startup. Include changing theme/options/visible service status as explicit read inputs; no render-time filesystem/configuration discovery or hidden browser text state.

Use full projection for small baseline data. The owner may traverse live private stores safely; only detached output/maps reach HTTP/stream threads. A coherent query projection does not require `text-snapshot` of every source on each key. Large text, range rendering and immutable-read sharing are later optimizations behind unchanged contracts, justified by measurement.

Install `(run,revision,output,map)` under one publication synchronization boundary, then nonblocking wakeups for each subscriber. Subscribe-plus-initial-read is atomic. Slow readers reread latest output; full wakeup slots mean already notified, not owner failure. Unsubscription/closed streams cannot roll back state or block commands. Copy/ownership discipline must prevent one consumer corrupting output used by others.

Use the existing POST-intent / GET-stream architecture, bodyless admission responses and key intent at execution time. New ordinary programmatic commands and timer/worker outcomes enter that same executor; never create an app-state queue competing with keyboard input. Under the existing admission mutex preserve successful bodyless acknowledgement before enqueue; input resolution/state mutation occurs later on the owner, not the request thread. Keep the existing resolver/Enter logging behavior for no-state commands and the current validated key envelope. Do not introduce printable-text insertion without the genuine buffer. Pointer-generation validation and uncertain-outcome epoch fencing remain the buffer plan's future transport contract; S0–S2 must not claim those unsupported input kinds are implemented. Stateful transport carries run/revision/projection status without creating a browser/session entity or retrying uncertain commands. End-to-end proofs inject test-only concrete models, captured command/renderer functions and test servers through the native seams; do not ship a fake production model or a public fixture API.

## 9. Checkpoint contents and format

Checkpoint current authored/durable content and metadata coherently. Buffer codecs cover authoritative node/source data, characters/properties, declared persistent annotations, semantic values, file/coding/saved-baseline information, and valid navigation/mode references. Distinguish lightweight owned read-only text from derived text: preserve authoritative values/rules and regenerate projections; do not persist HTML or another flattened document. Preserve unsaved drafts and unassociated text as content, not empty identities.

Exclude per-buffer undo/redo, removed objects retained solely by history, transient overlays/diagnostics, native handles/procedures, queues, source-map/line/render caches, jobs and temporary execution contexts. A durable field that lacks a codec makes checkpoint capture fail explicitly; never quietly drop it or relabel it transient. Definition references encode qualified names/data and resolve only through registered code; do not serialize closures. Missing definitions have explicit inactive/fallback or blocked policies and retain the original data.

The first envelope is one tagged UTF-8 Scheme datum with exactly the fields below, each present once; reject duplicate/unknown envelope fields rather than infer meaning. `format-version` is exactly `1`. Application/run IDs are nonempty Unicode strings generated by native runtime code, never file-supplied executable names. Sequence is a positive exact integer; captured revision/durable generation are nonnegative exact integers. `models` is a proper list of the section-6.3 ModelCheckpoint records, unique by qualified key. Each model record has exactly `key/schema-version/required/provided/references/data`, once each; future extension needs a format/schema rule, not ignored top-level fields. Models export in catalogue order, followed by retained opaque sections in their original relative order. Illustrative buffer body, not a complete buffer codec or native constructor syntax:

```scheme
(tuna-checkpoint
  (format-version 1)
  (application-id "persistent-app-id")
  (sequence 12)
  (captured-run "runtime-id")
  (captured-revision 87)
  (durable-generation 63)
  (models
    (model
      (key tuna/buffers)
      (schema-version 1)
      (required #t)
      (provided ((buffer "b1") (node "n1") (source "s1")))
      (references ())
      (data
        (buffer
          (id "b1")
          (label "Untitled")
          (root "n1")
          (nodes ((text-node "n1" "s1")))
          (sources ((editable-text "s1" "unsaved text\n")))
          (navigation (point (source "s1" 7)))
          (mode basic-text))))))
```

A real schema additionally validates/encodes properties, source kinds/protection, node roles/data/flow, selection/restriction/affinities, saved baseline and required ownership/reference fields. Identity tables avoid depending on native class layouts and permit graph references without Scheme shared-object syntax. This example does not silently define those missing fields as optional; the buffer codec must pass its explicit schema audit before integration.

Models have independent versions and registered pure migrations. Adding a model can extend the `models` sequence without changing the envelope. Missing an explicitly optional new model uses declared defaults; missing a required model, unknown required key, unsupported schema of any known definition or invalid reference blocks restoration. Registered definitions govern known keys' presence/schema rules: checkpoint data cannot downgrade a required known model to optional or redefine its dependencies. Preserve optional unknown sections as bounded opaque PlainData, not live executable models; subsequent captures must retain their bodies/version/identity manifests or refuse to overwrite. They cannot silently discard or reinterpret them.

Validate provided/reference kinds and IDs, ownership/uniqueness and per-model invariants after all native resources are allocated/resolved. Required references into unavailable optional models are a recovery conflict, not an excuse to point elsewhere. Inactive opaque sections reserve their IDs. Deleting a resource they reference must reject checkpoint export until the reference is resolved or an explicit later discard policy is approved.

## 10. Data-only reader and compatibility

Use a closed checkpoint-specific reader, not a mutable readtable inherited from user configuration. Explicitly disable Gambit read-time `#.` evaluation and graph/record/procedure serialization. `PlainData` consists of booleans, finite real numbers, Unicode scalar characters/strings, symbols and proper lists; integer-only fields still require exact integers. Reject complex/nonfinite numbers, opaque records/handles, procedures, cycles and direct mutable collection types. Codecs encode maps/vectors/other supported values as explicit versioned list records, not `#s` native objects. Never `load`, `include`, `eval`, import a checkpoint-named package or instantiate an arbitrary checkpoint-named class.

Accept exactly one datum followed by EOF/comments; reject empty/truncated/multiple datums, invalid Unicode, cycles, duplicate keys/IDs, illegal types, malformed ranges, oversized/deep input and unsupported versions. Apply limits during input/capture as well as post-parse validation. Verify native reader behavior with hostile examples; configuration of two flags alone is not evidence that all extension/resource-exhaustion paths are safe.

Decoder/migration factories come from approved startup definitions and are effect-free apart from constructing private in-memory resources. They run before those resources are exposed. Failed decode/reference validation installs nothing and preserves original files. There is no automatic import of historical Racket/older-Gerbil formats merely because their files are Scheme-readable.

Schema changes require encode/decode/migration fixtures, including round-trip retention of explicitly optional fields/payloads and downgrade refusal where data would be lost. Changing live storage backend must not change the checkpoint schema unnecessarily. Whole-heap binary serializers are not a substitute for this representation.

## 11. Startup restoration

1. Resolve the configured state path once before admission: initial stateful default `$XDG_STATE_HOME/tuna/checkpoint.scm` when XDG_STATE_HOME is an absolute nonempty path, otherwise `~/.local/state/tuna/checkpoint.scm`. Explicit paths expand at construction and remain fixed for the app lifetime. Acquire exclusive store authority and read/validate without changing existing files. Explicit `checkpoint-path: #f` is ephemeral; the no-durable-production-model default creates no directory/file/lock. Test stateful instances always supply scratch paths. Reject unsafe aliases/permissions rather than chmod arbitrary user data. A supplied durable production model enables automatic coherent checkpoint/restore by default; persistence is not generally opt-in.
2. With no checkpoint, construct declared initial models; do not create a file until a successful checkpoint. With valid data, decode/migrate supported model sections into private candidates.
3. Allocate resources with durable identity preservation and fresh live IDs; resolve source/boundary/navigation and cross-model references; validate the complete candidate. Do not expose half-restored resources or run normal user undo hooks.
4. Establish source/file checkpoint metadata without writing visited files. Recover exact stored unsaved content, not whatever bytes happen to be on disk. Changed/missing file associations are reported as conflicts/unverified associations; before any explicit save, check current disk fingerprint. Never mark recovered unsaved content file-clean merely because its app checkpoint loaded.
5. Recreate runtime definitions/callback bindings, caches and empty buffer histories. Missing mode/behavior definitions do not execute data or erase content; use an explicitly safe inactive/read-only fallback when the schema permits it, otherwise block recovery with a diagnostic.
6. Commit the validated root, bind a fresh run/admission identity, produce the first projection and only then admit normal input/subscribers. All tabs attach to that same state.

Invalid primary files remain untouched. Retain a last-good previous checkpoint and report whether it offers recovery, but do not silently fall back and overwrite a newer damaged primary. Operator recovery/start-without-restore must preserve existing files and disable writes to a blocked target until explicitly resolved; a full recovery UI/force-overwrite command is not required here.

Restoration promises equivalent logical content/navigation with compatible definitions, not pixel-identical rendering across renderer changes. Derived source formatting changes must map/detach positions by the schema's explicit policy; no silent clamping into an unrelated source. Invalid authoritative position data is a validation failure.

## 12. Periodic capture, ordering and crash safety

A wall-clock dirty check requests capture on the existing owner lane; do not wait indefinitely for idle typing. Coalesce outstanding timer requests. The selected initial interval is 5 seconds, configurable and subject to measurement. It is not a hard loss bound: busy commands, export failure, disk latency and write failure can extend the interval. A crash can lose changes after the last successfully synchronized checkpoint; no journal/exactly-once durability is promised.

Capture at a coherent boundary using model export methods. Do not let the I/O worker walk a mutable buffer or use shallow-copy metadata with live descendants. Reusing private immutable snapshots is allowed only after proving transitive ownership and generation correctness. Measure owner pause and retained memory for large text/source counts; full durable export may be linear even when typing is cheap.

The single writer owns one in-flight snapshot plus one latest pending snapshot. Newer pending data supersedes older requests without reordering file writes; ticket outcomes indicate coverage. Failed older data must not replace a newer pending snapshot. A completion names application/store/run identity and captured durable generation; ignore stale completions and never clear a newer dirty generation.

For a local supported filesystem, write a unique same-directory temporary file, finish encoding/flush, synchronize the correct file, replace the primary atomically, and synchronize the parent directory. Preserve a previous validated full checkpoint safely. Prove behavior for failures before/after replacement, permission errors, disk-full, cleanup, aliases/hard links and process termination. Report post-replacement synchronization uncertainty honestly; do not call it a proven durable success.

Use owner-private directories/files (initial 0700/0600, including the stable lock sidecar) and no content in logs. Create these modes only on new app-owned paths; do not repair/chmod existing user paths. Reject symlink/nonregular/multiply-linked data/lock files and unsafe containing directories; support only a validated local-filesystem adapter with required lock/sync/replace behavior. Unsupported stores block startup before admission. Hold an OS-backed exclusive store lock for the application lifetime; a second process targeting that path fails explicitly rather than merging/overwriting. Separate configured paths can support separate instances without a process-global state singleton. Also detect unexpected external file changes under the lock and stop automatic replacement. Do not infer stale-lock safety solely from a PID string.

Write failures retain latest pending data, produce visible/inspectable status and bounded retry backoff, and leave the previous good file usable. Failure/status updates do not make durable data dirty recursively. No checkpoint operation saves visited files or changes their saved-content baseline.

## 13. Shutdown and bounded waits

Close new admission under the existing ordering guard. Finish/cancel previously admitted commands only at safe boundaries, capture final durable state on the owner, and let the host/controller wait for the writer outside the owner. Writer completion must not require the blocked owner to dequeue another command. Never wait for one's own queued command or writer-status callback from inside an active update.

The selected initial final-flush deadline is 10 seconds, configurable. On timeout/failure report the uncheckpointed generation; do not claim it is saved, erase pending work, or terminate an applying owner to meet the deadline. A caller abandoning a wait does not cancel accepted work or authorize replay. Cooperative stop failure returns a pending/failed result requiring an explicit host/owner decision, not a hidden `thread-terminate!` path.

Close subscribers, timer service and writer only after their defined final states, invalidate capabilities/jobs and release store authority. State disposal is lifetime management, not user undo. Process/OS forced termination can still lose the latest in-memory changes; document the checkpoint limitation rather than promising recovery of every acknowledged key.

## 14. Implementation seams, ownership and handoff

Only create production modules with behavior/tests; no placeholder checkpoint/buffer modules. Core must compile/test before concrete checkpoint implementation exists. Keep dependencies acyclic: private shared protocol → update/core and checkpoint independently → final facade/runtime composition. The core imports the neutral `CheckpointService` interface, not a nonexistent concrete checkpoint module. Final facade/runtime assembly selects the real service after its handoff. Minimal private-core/facade placement may follow actual native compilation needs; no second ownership engine.

| Path relative to Tuna | Exclusive component owner / responsibility |
|---|---|
| `tuna/private/state-protocol.ss` | Core writer: shared typed StateModel/StateModelDefinition/CheckpointService interfaces, construction/read/update capabilities, outcome/capture DTOs and private owner bridge only. No generic state framework. |
| `tuna/app-state.ss` (private core split only if needed for acyclic assembly) | Core writer: opaque root/catalogue, construction/reference validation, scope guards, revisions, read/update results, rendering/publication/subscriptions. Re-export only section-6 public inventory; final assembly wiring belongs to runtime pass. |
| `tuna/private/update.ss` | Core writer: one shared prepared-step/journal kernel for app and later buffer, owner/phase checks and continuation-safe closure. Not a public transaction API. |
| `tuna/checkpoint.ss` | Checkpoint writer after core handoff: concrete CheckpointService, envelope/model validation, restore, capture scheduling, writer/ticket/retry state and truthful outcomes. Depends on neutral protocol, not app-state implementation. |
| `tuna/private/checkpoint-file.ss` | Same checkpoint writer: bounded closed reader/encoder and native local-store adapter, stable sidecar locking, atomic replacement/sync, previous-good/conflict checks and cleanup. |
| `tuna/{input,server,main}.ss`, `tuna/private/input-runtime.ss`, `{build.ss,manifest.ss}` as needed | Runtime writer after checkpoint handoff: compose service/core on existing lane, ordinary command bridge, current/initial projections and stream fan-out, build registration and cooperative lifetime. The manager-approved private native bridge/executor owns the existing events channel lane only; input.ss retains its live resolver and delegates execution through a per-event lookup closure. Programmatic `main(config, app: app)` preserves existing zero/config argument startup; supplied roots restore/project before HTTP admission, while the default creates no root/service/files. Preserve current input/customization behavior. |
| `tuna/buffer.ss`, related planned buffer modules | Later conditional S3 writer: genuine buffer participant/codec, not an S0–S2 production fixture. |
| `tests/fixtures/app-state/core-test.ss`, `tests/fixtures/app-state/` | Core-owned test paths: two native concrete models, read/identity/rollback/continuation/outcome/projection proofs. Fixture providers are test-only. |
| `tests/checkpoint-test.ss`, `tests/fixtures/checkpoint/` | Checkpoint-owned test paths: data/migration/security/budget fixtures, scratch stores and synchronous native fault hooks. |
| `tests/app-state-runtime-test.ss`, existing `tests/input-test.ss`, `tests/keyboard.test.mjs`, `tests/run.py` as needed | Runtime-owned test paths: isolated concrete-model test servers/restart/continuous-input/two-browser proofs and existing default-input regression coverage. Shared runner changes are serialized with each owner's pass. |

The manager admits exactly one writer at a time in the Tuna checkout; readers may inspect concurrently. Order: (1) core/protocol/update and isolated core tests, (2) checkpoint/file adapter and isolated tests, (3) runtime/facade/build assembly and integration regressions, then conditional real-buffer work. Component writers do not concurrently edit the shared protocol, app facade, build files or test runner. A required ABI change returns to the manager for coordinated amendment; no ad hoc copied DTOs or parallel journals. No production `session.ss`, layout/window implementation, persistent collection dependency, event store, provider framework or code-reloading machinery. Gerbil/shared installations, customization internals and user state remain read-only.

### 14.1 Private checkpoint/core/runtime ABI

These names describe the minimal internal typed seam, not additional public facade exports. Concrete service implements the native interface; no table of callbacks. The private runtime bind operation attaches a native OwnerBridge and optional CheckpointService exactly once before app-start!, under exclusive bootstrap ownership. The bridge implements admission/submission/close-admission on the existing channel/mutex; it owns no additional queue or mutation thread. Core owner-only/ephemeral tests require no concrete production checkpoint import. Stateful persistent startup without the concrete service is an explicit not-configured failure, not an empty successful store. `CheckpointService.open` consumes fixed path/policy and validated definitions under exclusive startup ownership, returns a typed restore bundle or blocked/failed diagnostic, and owns the store lease. The bundle contains persistent app ID, loaded sequence/generation, decoded model sections and retained opaque sections, never live models. No-store creates no file/thread/lease. Core creates/links candidate models, commits root and first projection before admission; candidate failure closes the service without automatic writes. Successful restore sets current/saved durable generation to the loaded value; migration/optional-default changes advance current once and leave saved unchanged. A fresh defaulted state starts revision/generation 0, saved generation `#f`, and is eligible for its first checkpoint even without a later edit. Startup establishes a fresh run ID and revision 0 after successful construction; old transports/jobs are fenced by run identity.

Core supplies service capture with a detached `CheckpointCapture`: `application-id`, `run-id`, `revision`, `durable-generation`, complete ModelCheckpoint sections and retained opaque sections, plus the validated policy used for that capture. Sequence is allocated monotonically by the single writer for each write attempt, above the loaded/successful sequence; retries do not reorder captures. Only successfully synchronized sequence/generation becomes saved coverage. After a crash only committed on-disk sequence continuity is promised, not continuity of unseen failed attempt numbers. Service does not call back into live models, render or mutate app state from its writer. The internal native method contract is:

| CheckpointService method | Signature / ownership |
|---|---|
| `open` | `(path, policy, definitions) -> RestoreBundle or StartupResult blocked/failed`; exclusive startup, before models exist. Missing file returns a defaults bundle, not decoded empty models. `RestoreBundle` has path/format/application-id/sequence/generation, decoded sections, opaque sections and migrations; IDs/counters are `#f` for absent file. |
| `activate!` | `(application-id, run-id, current-generation, saved-generation) -> void`; owner after successful construction/first projection, once. Until activation no timer/write admission. |
| `request!` | `(CheckpointCapture) -> CheckpointRequest`; owner boundary, validates detached capture and run/store identity, coalesces pending latest data. Core avoids export for saved/in-flight/pending coverage already known. |
| `info` | `() -> detached service status`; safe outside owner, no live-model reads. Core merges its current generation into public CheckpointInfo from coherently cached app status. |
| `policy!` | `(CheckpointPolicy) -> void`; owner safe boundary; next work uses new limits/schedule, accepted snapshots retain their policy. |
| `await` | `(CheckpointTicket, timeout) -> CheckpointOutcome/'timeout`; outside owner, repeatable synchronized ticket completion, no queued owner dependency. |
| `close!` | `(deadline-seconds) -> closed/pending/failed service result`; controller after final owner capture (or unactivated startup failure), stops new service admission, flushes/cooperatively joins/releases only finished resources. Idempotent continuation of the same close. |

Trusted in-repository model providers import the private state-protocol module alongside the public model interfaces. It supplies typed `new-definition-info`, `new-model-info`, `new-decoded-model-data`, and `new-model-checkpoint` constructors taking exactly the section-6.3/6.4 fields; validated definitions/manifests are owned, not borrowed mutable slots. These constructors adopt already-detached provider-owned values; ownership transfers to the DTO, without a redundant second full copy. They are not public facade exports or a provider registry. The same private module supplies the distinguished defaults marker, `construction-register-resource!`/`construction-resolve-resource` operations, and `export-budget-charge!` (budget plus byte/object increments and prospective depth/token byte counts, before allocation). These helpers validate remaining allowance/namespace/phase properties, not arbitrary application meaning. Providers import private/update for typed prepared-change/step construction and the owner/update bridge; that module alone owns journal/commit operations. No provider needs to invent structurally equivalent ad-hoc DTOs, expose raw stores or import checkpoint-file machinery. Renderer callers instead use public new-projection-data and do not require private imports.

The timer's owner bridge is supplied by the one-time runtime bind, not discovered from globals. This private ABI is shared in state-protocol and implemented by the checkpoint component; it is not re-exported as a second checkpoint API.

Core/runtime supplies one native owner submission bridge into the existing events lane, including typed update/query work, coalesced capture requests and safe status invalidations. The bridge checks lifecycle/admission identity and keeps keyboard acknowledgement ordering unchanged. The timer enqueues at most one outstanding capture request; the owner handles it between updates. Detached writer completion settles checkpoint tickets/status directly under its synchronization boundary before scheduling an optional owner-visible transient status update. A host awaiting final flush never depends on the owner consuming a completion callback. App/store/run identity checks reject stale completion; saved generation cannot advance beyond actually synchronized coverage or clear newer dirtiness. No callbacks while publication/writer locks are held.

### 14.2 Native local-store adapter and lifecycle

The checkpoint file component owns a private native interface/concrete local implementation for acquire/read/replace/release behavior and synchronous failpoints in tests. Use standard Gerbil I/O, OS-backed stable-sidecar locks, errors, mutexes/condition variables and `spawn-thread` for joinable workers; no private FFI, PID-only lock or extension hook registry. Read while holding store authority; replacing the primary must not replace/unlock the sidecar inode. Adapter outcomes preserve original native failure plus exact phase, replacement/synchronization status, resulting own-file identity and cleanup reports; these feed CheckpointOutcome without treating post-replace uncertainty as saved. Track own replacements even when sync fails, so a retry does not misidentify them as an external edit. If installed native primitives cannot establish the required local-store guarantees, report the exact blocker to the manager rather than silently weaken crash safety.

Controller stop closes admission under its existing ordering guard, then requests an owner boundary after earlier admitted work. Owner final capture precedes service flush/close; controller waits outside owner with one monotonic deadline. Do not cancel a write while its adapter is applying replacement/sync or release its lease while that worker still owns it. Deadline expiry leaves pending work/resources live and returns pending; repeated stop can finish them cooperatively. Close model resources and subscriptions only after owner drainage and defined writer final states. Cleanup and native errors are ordinary synchronous/cooperative behavior; no force terminating an applying owner, asynchronous interrupt exception or hidden recovery retry framework.

## 15. Milestones and dependency with buffer work

### S0: freeze contracts and prove mechanisms

Audit the complete candidate interface/schemas, model update/identity/codec protocol and private buffer-host composition. Prove native typed definitions, deep read isolation, owner/capability guards, shared update rollback for two small models, continuation/cancellation behavior, closed reader, writer locking/replacement/synchronization and repeatable timed outcomes in the isolated harness. Stop if cross-model atomicity is only a wrapper after buffer commit or the reader can execute data. No future layout implementation.

### S1: minimum end-to-end application state

In isolated test servers, wire a small test-only concrete non-buffer model through existing keyboard intent → owner update → committed data → escaped HTML projection → all subscribers. Production's no-model default retains its current input behavior and creates no state files. Prove startup/current projection acquisition, two browser mirrors, slow-reader coalescing, render failure after commit and no mutable state on HTTP threads. No input/textarea/contenteditable workaround. The fixture demonstrates the pipeline only in tests, not as a shipped fake buffer/model API.

### S2: checkpoints and restart

Implement periodic coherent fixture export, versioned Scheme format, one writer/latest pending, strict startup restore, previous-good preservation, dirty/written generations, conflict/private-file policy, retry and final flush. Prove restart equivalence, malformed/unknown input protection, stale completion ordering, continuous-input scheduling and unsafe shutdown rejection. Add/migrate a second fixture model without changing the envelope or executor. Stop when the mechanism is correct; do not add a general state language.

### S3: real buffer participation and content recovery

After buffer storage/model milestones exist, attach the one real buffer to the common host and implement its explicit codec. Compose that production buffer model through the proven seams; test-only fixture providers remain tests. Prove text/properties/semantic-node data and navigation round trips, no empty-buffer metadata-only “recovery,” fresh live IDs, preserved durable references, dirty-file state, read-only contributions, safe unresolved definitions and empty per-buffer undo after restart. Confirm every attached buffer mutation reaches one application update/publication without duplicate journaling/history.

The sequence is S0–S2 first, then the buffer's storage/structured-model work with shared-kernel integration, then S3 before claiming real editing recovery. File association/checkpoint details are completed with the buffer file milestone; do not simulate unsupported file behavior in S2. Migrate no user data in this plan.

## 16. Acceptance matrix

| Family | Required evidence |
|---|---|
| Ownership/types | Native `:gerbil/core` compilation, one owner, off-owner/stale/closed capability rejection, no leaked state aliases or custom-macro dependencies. |
| Atomic composition | Two models change together; failure at preparation/apply/commit boundaries leaves no precommit partial state/history; continuation/cancellation/escape and re-entry cases; attached buffer uses the same kernel. |
| Clocks/no-ops | One application revision per real update, local buffer/source generations only when affected, durable generation only for exported changes, no-op/undo/render-retry distinctions. |
| Render/publication | Read-only deterministic interpretation, output/map/revision coherence, render errors after commit, atomic subscribe/current acquisition, latest-state coalescing and stream isolation. |
| Forward additions | Register an optional fixture model, restore an older checkpoint with explicit defaults, migrate a schema, preserve optional unknown payloads/IDs and reject unsafe required references without changing the envelope. |
| Reader/security | `#.` rejection, no code/record imports, cyclic/graph notation and unsupported types rejected, invalid Unicode, duplicate/oversized/deep/multiple/truncated data, malicious names treated as data. |
| Snapshot isolation | Writer payload survives subsequent edits; modifying returned values cannot affect model/other readers; no shallow nested aliases. |
| Checkpoint ordering | Single writer, bounded in-flight/pending data, stale success/failure cannot clear current dirty data or replace newer pending work, exact ticket coverage, ongoing input does not indefinitely debounce capture. |
| Filesystem | Private mode/path checks, lock exclusivity/crash release, alias/hard-link/external-change refusal, failpoints around flush/sync/rename/dir sync, previous-good preservation and truthful post-replace uncertainty. |
| Startup/recovery | Restore before admission, content/positions/data round trip, namespace/ref uniqueness, fresh live identities, changed/missing files reported without writes, blocked restore never overwrites source. |
| Undo/file semantics | Per-buffer histories empty on restart, working runtime undo remains independent, checkpoint does not clear file-modified or claim to save visited files. |
| Lifecycle | Closed admission/draining order, final capture/flush outside owner waits, timeout does not cancel/replay, no termination in apply, subscription/writer cleanup and actionable failure. |
| Performance | Owner capture pause, full edit-to-projection latency, queued-input delay, source/model count, steady/peak snapshot memory and writer backpressure measured separately. |

Use repository-supported isolated validation (`cd /home/jay/Code/workbench-gerbil/tuna && PYTHONDONTWRITEBYTECODE=1 python3 tests/run.py`) and the established app build (`make all` / `gerbil build`) in isolated scratch for the authorized implementation. Derive additional commands from actual tools. Planning/research did not execute these acceptance tests or claim a working state implementation.

Characterize realistic small data first, then larger text/source counts. A periodic full export is linear work; do not confuse passing gap-edit benchmarks with a responsive capture/render path. Future incremental snapshots, sidecar text blobs or structural sharing must preserve whole-checkpoint coherence and follow measured bottlenecks, not become prerequisites without evidence.

## 17. Audit closure and implementation boundary

The manager approved native StateModel/definition interfaces with concrete `new-` providers, two-phase construction/index/link validation, private CheckpointService protocol/build ordering, ordinary captured renderer/commands, explicit joined nested results and the selected validated budgets/defaults. Sections 6/9/11/14 now fix meaningful read/update/factory/export/decode/identity, outcome, lifecycle and I/O seams for exclusive implementation writers. They are implementation requirements, not evidence of compilation, safe native filesystem behavior or passing end-to-end proof. Keep deadlines/path/limits reviewable from measurements and failure fixtures; do not silently revise behavior or widen exports.

Owner-authorized scope is S0–S2 in Tuna and its tests, with exactly one writer at a time. Existing user-owned plans/research/support material must be preserved. No staging/commits/reset/clean/remote mutation, Gerbil source/shared-installation edits, production/user checkpoint reads/writes, or wholesale historical implementation imports. State tests use explicit scratch paths. Every Gerbil source edit must establish native MCP balance baseline first, run balance immediately after each edit, then contextual syntax checking before compilation/testing; a module-context mismatch requires a proved checkout-local expansion fallback, not an unrelated snippet or compile-before-syntax shortcut. This documentation audit edits no Gerbil source and claims no MCP/source/build/test proof.

The earlier companion assumption that recovery waits until after its baseline is superseded by this application pipeline and common private host. Buffer sections 3/13/14/17 and related scope/identity paragraphs align without approving all buffer milestones or resolving its independent editing API audit. S3 remains gated: audit the genuine buffer codec for every declared durable field, prove shared journaling/history and real unsaved content/navigation recovery, then claim buffer recovery. S0–S2 fixture proof cannot satisfy S3, file-saving, pointer selection, undo or future window/mode behavior. No fabricated production buffer/model, session object or unrelated cleanup.
