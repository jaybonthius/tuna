# Prior state and recovery lessons for Tuna

## Result

Recommend **one application-state coordinator that owns module-defined resource objects and invokes existing buffer operations on the same serialized command lane**. It should coordinate identity, attachment, lifecycle, persistence and projection invalidation—not introduce a second generic transaction/revision/publication layer around the buffer. Preserve the proposal's buffer update/history boundary. This is a recommendation for planning, not authorization to implement or to settle unresolved owner choices.

## Evidence boundary and relied-on prior documents

Earlier research documents actually relied on (exact source paths; copy these into Tuna research if retaining this report):

- `/home/jay/Code/workbench-gerbil/research/tuna-host-neutral-state-architecture.md`
- `/home/jay/Code/workbench-gerbil/research/tuna-current-state-boundary.md`
- `/home/jay/Code/workbench-gerbil/research/gerbil-host-neutral-state-mechanisms.md`
- `/home/jay/Code/workbench-gerbil/research/functional-application-state-patterns.md`

Also inspected current proposal `/home/jay/Code/workbench-gerbil/tuna/plans/tuna-buffer-model/spec.md`, historical `/home/jay/Code/tuna/docs/plans/in-memory-editor-state.org`, `/home/jay/Code/tuna/docs/reference/emacs-research.md`, and the research-corpus index `/home/jay/Code/workbench-racket/docs/tuna/research/README.md` (not a prior state implementation authority). The index explicitly warns that its materials are historical, sometimes contradictory, and must not be promoted into current core decisions.

**Current Tuna facts:** the checkout at `/home/jay/Code/workbench-gerbil/tuna` is the newer Gerbil app. Its scope/context says it currently has an input loop and static body; the buffer model is a proposal, not present behavior. The buffer spec itself identifies commit `bf7860533738e6c1e162c9ae019b53f5654287da` as its implementation reference and says no implementation is authorized. The host-neutral architecture report's claims about existing command lane cite a different snapshot/commit (`806ece2...`) and paths such as `tuna/lib/runtime.ss`; treat those as historical architecture evidence, not confirmation of this checkout's current symbols. Do not infer a persistent app-state subsystem exists today.

## Reusable lessons

### Ownership and types

- The Gerbil-side host-neutral recommendation is runtime-instance-owned, owner-confined mutable resources with detached revisioned snapshots; it rejects process-global authoritative state and unrestricted mutable references. Its strongest transferable lesson is *ownership protocol*, not a mandatory universal immutable root or generic store. See source report sections “Decision,” “Required invariants,” and “Public and private seams.”
- Prefer typed, module-owned state structs and operations. An untyped key/value registry appears extensible but loses domain invariants, ownership, migration/type checking, and makes arbitrary extension payloads silently part of persistence. Unknown extension data must be an explicit compatibility policy, not accidental acceptance of arbitrary object graphs.
- State graph can contain opaque resources (buffers, future layouts, navigation contexts) with owners; persistence should encode supported durable values, not serialize live handles, closures, locks, streams, runtime state, or rendered HTML.
- Never expose mutable internal stores through getters or shallow “snapshots.” Gerbil structs and nested aggregates remain mutable; shallow copies preserve aliases. Detached snapshots require deep ownership or immutable-by-contract reachable data. This makes aliasing an API invariant and a persistence decoder concern.

### Publication and projections

- One coherent publication root is useful for readers, but a second coordinator revision/transaction around buffer revision creates duplicate authority and ambiguity about commit ordering. Let buffer update remain the atomic unit for buffer content/history. Coordinator-level commands that change multiple domains must use one outer serialized command boundary and stage/validate before applying; if buffer APIs cannot participate in a shared candidate, do not promise all-or-nothing across buffer and app resources.
- Publish cheaply by advancing a coordinator generation/invalidating dependent projections only after a successful outer command; projections (HTML, layout, navigation summaries) are derived and can be recomputed from authoritative resources. Coalesce wakeups; they are invalidations, not an event log. Avoid copying the whole graph on every keystroke merely to publish.
- A buffer edit followed by a failing layout update is the critical partial-commit hazard. Either ensure all fallible validation/preparation happens before buffer commit and post-commit steps are non-failing, or report the buffer commit honestly and recover/republish actual state. Do not pretend the outer operation rolled back history or external effects.

### Persistence and recovery

- Historical Racket plan `/home/jay/Code/tuna/docs/plans/in-memory-editor-state.org` proposes one tagged datum `(tuna-state (version 1) (state ...))`, strict single-datum reading, explicit version/shape validation, decoded immutable values, full state validation, and leaving invalid source untouched. This is a useful format discipline, not a Gerbil format or current requirement.
- It separates synchronous load-before-exposure from asynchronous snapshot writes; one writer owns a latest-pending slot, writes atomically, retries failures, and shutdown flushes final state. These address ordering and torn-file hazards better than multiple independent writers. Any adaptation must establish temp-file/rename durability guarantees for the selected platform/filesystem; atomic rename alone may not guarantee power-loss durability.
- Schema version must be explicit and migrations tested. Decide unknown fields/extensions deliberately: reject unsupported critical data, preserve only explicitly opaque/versioned extension payloads if round-trip guarantees are required, and never silently discard data on load/save.
- Historical plan's recovery tests include deterministic snapshots, retry, final flush, strict loading. Add recovery-specific tests for empty-buffer restoration, metadata-only records accidentally restored without text, resource identity/anchor mapping, aliases, unknown extension data, stale writer ordering, corrupt/truncated files, and migration. These are proposed tests, not observed defects in current Tuna.

### History, identity, anchors

- Buffer spec defines compound atomic updates and per-buffer undo/redo (sections 13–17; especially `call-with-buffer-update`, history and recovery separation). Persistence must not replay serialized undo internals unless explicitly designed; generally persist current durable content + metadata, not history journal.
- Durable identity cannot be a positional child index or transient object address. Persist stable IDs and validate uniqueness/ownership on restore. Restore navigation only after its target source/node has been reconstructed; map anchor offsets through an explicit identity/generation policy. Stale/deleted targets should detach or fall back by declared policy, never silently point into unrelated content.
- The proposal's distinction between node identity, text-source identity, source generations and live anchors is directly useful for persistence. Its current one-buffer/shared-navigation constraint means independent navigation requires a later app-level context per view/session, not adding another point/history to each text source.

## Application-state coordinator against buffer proposal

A minimal coordinator can own typed app state such as a current buffer handle now, and later stable resource IDs / layout records / navigation contexts. It should not implement windows or layouts in this scope. The buffer remains responsible for content tree, text source ownership, anchors, point/mark, revision, atomic `call-with-buffer-update`, and per-buffer undo history. Coordinator owns which resources are live/attached and durable app-level metadata; it calls buffer procedures rather than wrapping their internal mutations.

For future independent navigation, define separate navigation-context values referring to a buffer and stable positions; do not turn current buffer point into per-source point or alter existing proposed `buffer-context`, point, mark, selection procedures. Until owner approves the semantics, current proposal's shared navigation across browsers remains intact. A future layout may refer to buffer/context IDs and derive display; it need not own or duplicate text/history.

For coordinator operation, validate IDs/references and prepare all candidate metadata before invoking buffer mutation. Use the existing serialized owner as the sole writer. Make the buffer update the content commit boundary; coordinator publishes a single application snapshot/invalidation after the command reaches its defined final state. Do not create a second per-buffer revision or duplicate undo system. Cross-domain atomicity is an unresolved contract: if a command must atomically alter layout plus buffer content, buffer API needs an explicit composition seam before that guarantee can be offered.

## Source and citation notes

- Buffer proposal: `/home/jay/Code/workbench-gerbil/tuna/plans/tuna-buffer-model/spec.md` lines 54–94 (ownership/invariants); 172–196 (locals/updates/history/file); 213–274 (identity/anchors); 345–380 (atomic updates, revisions, per-buffer undo); 399–404 (recovery explicitly later); 455–490 (runtime boundary and implementation files); 552–558 (approval boundary). Current proposal, not implementation.
- Historical Racket state plan: `/home/jay/Code/tuna/docs/plans/in-memory-editor-state.org` lines 1–35 (state/commands); 37–68 (schema/reader); 70–78 (worker/acceptance). It proposes immutable global state and locking, unlike selected Gerbil host-neutral mutable-resource direction; do not combine them uncritically.
- Host-neutral architecture report: `/home/jay/Code/workbench-gerbil/research/tuna-host-neutral-state-architecture.md` lines 3–18, 69–92, 128–184. Historical research recommendation, not app-state decision.
- Current-state boundary report: `/home/jay/Code/workbench-gerbil/research/tuna-current-state-boundary.md` lines 3–86 distinguishes admission, actions, dynamic values and lifecycle in its then-current runtime snapshot.
- Gerbil mechanisms report: `/home/jay/Code/workbench-gerbil/research/gerbil-host-neutral-state-mechanisms.md` lines 168–219 (mutable aggregates/copy aliasing), 239–269 (failure boundaries), 315–392 (architectural alternatives).
- Functional patterns report: `/home/jay/Code/workbench-gerbil/research/functional-application-state-patterns.md` lines 285–328 (snapshots vs event sourcing), 377–459 (owner-confined mutation tradeoffs).
- `/home/jay/Code/tuna/docs/reference/emacs-research.md` is a bibliography/reading map, not evidence that Tuna should clone Emacs's buffer/undo/recovery model.

## Unresolved owner decisions (not defaults or authorization)

1. Is app-state persistence in scope now, and what state is durable versus ephemeral?
2. Is there one global app state per runtime instance, and what is recovery behavior for multiple runtime instances?
3. What exact atomicity is required across buffer mutations and future app metadata/layout? Existing buffer update procedures must remain compatible.
4. Which IDs persist, how anchors/navigation restore when content changes, and what is fallback for missing targets?
5. Is undo history persisted? Recommendation is no absent an explicit requirement.
6. Unknown schema versions/extensions: reject, preserve opaque payloads, or migrate? What compatibility guarantee is required?
7. Snapshot cadence, write coalescing, retry/error visibility, shutdown deadline, and durability/fsync requirements.
8. Whether future independent navigation is per layout leaf, session, or another explicitly owned context; current buffer proposal mandates shared navigation today.

Residual risk: historical artifacts describe distinct runtimes and conflicting state philosophies. Recovery edge cases listed above are test targets inferred from architecture, not confirmed bugs. No source implementation, tests, private `.state` checkpoint contents, or toolchain were inspected or modified.
