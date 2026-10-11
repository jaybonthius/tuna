# Tuna profiler tree UI research

## Conclusion

**Recommended:** replace the specialized profiler table with one private, recursively rendered span tree while retaining Tuna’s existing latest-only coordinator, explicit revision provenance, delivery reservation bound, fail-open behavior, and independent `/profile/subscribe` stream.

Do not add a profiler framework, event bus, sessions, signals, JavaScript, command-specific records, or a flame chart.

## Review findings

1. **Blocker — specialized model cannot represent the requested tree.**  
   `ProfileSnapshot`, `StageSnapshot`, and `DeliverySnapshot` encode fixed columns and shallow parent labels rather than arbitrary identity-preserving nesting: `tuna/tuna/private/profiler.ss:80-110`, `tuna/tuna/private/profiler.ss:250-288`. The renderer reproduces that schema as a fixed definition list and separate stage/delivery lists: `tuna/tuna/private/profiler-render.ss:47-67`, `tuna/tuna/private/profiler-render.ss:69-125`.

2. **High — a renderer-only change would not deliver automatic live-call nesting.**  
   Current instrumentation manually wraps only `normalize`, `resolve`, argument acquisition, and target transition: `tuna/tuna/private/application.ss:303-367`. Central live invocation seams are `function-cell-ref`, `invoke-action`, and `invoke-state-transition`: `tuna/tuna/lib/bindings.ss:168-180`, `tuna/tuna/lib/bindings.ss:441-452`, `tuna/tuna/lib/bindings.ss:471-475`.

3. **High — dynamic parameter inheritance is not asynchronous propagation.**  
   Current synchronous recording checks command-owner identity before accepting a stage: `tuna/tuna/private/observation.ss:191-233`. The existing test demonstrates that an inherited child-thread parameter must not create a child span: `tuna/tuna/test/profiler-test.ss:425-447`. Delivery must continue using coherent root provenance and an explicit subscriber-thread handoff.

4. **Medium — current outer morphs can overwrite disclosure state.**  
   The profiler stream outer-morphs `#tuna-profiler`: `tuna/tuna/private/http.ss:301-329`, but the renderer emits plain `<details>` without `data-preserve-attr`: `tuna/tuna/private/profiler-render.ss:69-80`. Datastar v1.0.2 synchronizes or removes incoming attributes unless listed for preservation.

5. **Medium — wrapping stored live procedures is risky.**  
   A generic rest-argument wrapper could change procedure arity and identity exposed through `function-ref`. The approved contract requires existing public signatures and arities to remain unchanged: `plans/tuna-profiler/spec.md:37-47`, `plans/tuna-profiler/spec.md:130-148`.

6. **Medium — the new product direction supersedes parts of the approved profiler specification.**  
   The current specification explicitly requires fixed curated metadata and fixed stage timings: `plans/tuna-profiler/spec.md:13-23`, `plans/tuna-profiler/spec.md:65-74`. It should be revised before implementation rather than treating the tree as a cosmetic follow-up.

## Minimal generic model

Use private mutable builders and detached final snapshots, preserving the current publication discipline.

### Mutable builder

```text
SpanBuilder
  id                 exact internal integer
  parent             SpanBuilder or #f
  label              bounded symbol: command/runtime/function/action/transition/delivery
  description        copied bounded string or trusted interned live name
  start-tick
  end-tick
  status             bounded symbol
  async?             boolean edge classification
  children           ordered builders
```

### Published snapshot

```text
ProfileSnapshot
  root               ProfileNodeSnapshot
  omitted-deliveries exact nonnegative integer

ProfileNodeSnapshot
  id
  label
  description
  inclusive-us
  self-us
  status
  async?
  children
```

A nested snapshot does not need a public parent field. The internal `id` supplies delivery correlation and stable DOM identifiers. Do not add arbitrary tags, attributes, events, arguments, results, or metadata maps.

The separate omitted count remains justified because it reports bounded-detail loss rather than a measured span. It can render as one footer beneath the tree.

### Example tree

```text
command  keydown i / KeyI                         changed
├─ runtime  admission
├─ runtime  queue
├─ runtime  dispatch
│  └─ transition  tuna-dispatch
│     ├─ runtime  normalize
│     ├─ runtime  resolve
│     ├─ runtime  acquire-arguments
│     │  └─ function  tuna-acquire-input-arguments
│     └─ runtime  transition
│        └─ transition  tuna-increment
├─ runtime  publication
└─ delivery  wake 1 → revision 1                 async, sent
   ├─ runtime  snapshot
   ├─ runtime  render
   │  └─ function  tuna-render-state
   └─ runtime  send
```

## Nesting and propagation

### Synchronous spans

Use one private current-profile/current-span context only while an owner explicitly installs it.

For each synchronous span:

1. Verify the context belongs to `current-thread`.
2. Allocate a child under the current span.
3. Read its start tick.
4. Parameterize the current span to that child.
5. Run the body exactly once.
6. Close it in `try`/`finally`, recording success or failure without replacing the body’s result or exception.

This generalizes the current unwind-safe stage behavior at `tuna/tuna/private/observation.ss:198-233`. A context inherited by a newly spawned thread must run the body unprofiled unless explicitly reinstalled.

### Asynchronous delivery

Keep Tuna’s current explicit chain:

1. State installation stores opaque provenance in the same root that receives the revision and fans out nonblocking invalidations: `tuna/tuna/private/runtime.ss:168-193`.
2. A subscriber coherently copies revision, value, provenance, and snapshot ticks under the runtime mutex: `tuna/tuna/private/runtime.ss:148-166`.
3. The subscriber waits for command readiness and reserves a bounded delivery child using that exact provenance: `tuna/tuna/private/profiler.ss:413-455`.
4. Only then does it explicitly install a subscriber-thread context rooted at the asynchronous delivery node while snapshot/render/send execute.

Do not infer parentage from the current profile, wake revision, a dynamic parameter, or the completion observer. Preserve command-root closure before normal completion and delivery release: `tuna/tuna/private/runtime.ss:264-283`.

The delivery edge must carry `async? = #t` because its timing need not be temporally contained within the already-closed command root.

## Automatic instrumentation seams

### Recommended approach

Instrument named invocations without replacing stored procedure objects:

- Have `defun`, `defaction`, and `deftransition` macro-generated lexical wrappers call one private span helper around their existing cell lookup and invocation. Their generated fixed-arity lambdas remain fixed-arity: `tuna/tuna/lib/prelude.ss:74-124`, `tuna/tuna/lib/prelude.ss:126-200`, `tuna/tuna/lib/prelude.ss:202-262`.
- Instrument `invoke-action`, `invoke-action-with-context`, and `invoke-state-transition` centrally because runtime dispatch bypasses macro wrappers: `tuna/tuna/lib/bindings.ss:441-452`, `tuna/tuna/lib/bindings.ss:471-475`.
- Wrap action context acquisition as a `runtime/acquire-arguments` child and the actual implementation as the named `action` child.
- Add the same private helper to Tuna’s manually constructed live wrappers:
  - `tuna-acquire-input-arguments`: `tuna/tuna/private/application.ss:294-301`;
  - `tuna-dispatch` and `tuna-increment`: `tuna/tuna/private/application.ss:369-391`;
  - `tuna-render-state`: `tuna/tuna/private/render.ss:65-76`.
- Convert existing runtime lifecycle and application-stage calls into ordinary generic spans rather than retaining separate stage records.

This is a narrow private call helper, not a public tracing macro or listener bus. Outside an explicitly installed profile context it should be a cheap branch followed by the original call.

### Alternatives

| Option | Assessment |
|---|---|
| Wrap every implementation stored by `define-function!`, `define-action!`, and `define-state-transition!` | Broadest coverage, but risks changing public procedure identity and arity. Not recommended. |
| Instrument only current application/runtime call sites | Lowest compatibility risk, but future live functions silently disappear from profiles. Does not meet automatic-instrumentation intent. |
| Add a public tracing macro or generic event bus | Explicitly out of scope and unnecessary. |

A deliberately captured bare procedure returned by `function-ref` should remain an escape hatch rather than changing its identity contract.

## Inclusive and self time

Show both:

- **Inclusive:** `end - start`.
- **Self:** inclusive minus the inclusive durations of complete direct **synchronous** children.
- Never subtract asynchronous delivery children from command self time.
- Clamp at zero if a failed or irregular clock produces inconsistent partial data; instrumentation remains fail-open.
- Show `—` for unfinished or untimed nodes.

Koyo shows only inclusive duration, which is adequate for sparse manual instrumentation but double-counts nested automatic calls: `/home/jay/Code/koyo/koyo-lib/koyo/profiler.rkt:120-159`, `/home/jay/Code/koyo/koyo-lib/koyo/profiler.rkt:173-191`.

## Metadata reduction

### Retain

- Root description containing key and code, for example `keydown i / KeyI`.
- Generic node label, description, status, inclusive/self duration, async marker, and children.
- Wake/delivered revisions only as the delivery node’s escaped description when useful for proving coalescing.
- Omitted-delivery count.
- Internal profile generation, node IDs, readiness, and provenance strictly as private routing state.

### Remove from the published/UI schema

- Constant `POST` and `/`.
- Key location, repeat flag, and modifiers.
- Standalone resolved-transition field; the named transition span replaces it.
- Dedicated before/installed revision rows; exact revision correlation remains internally tested, and an optional publication description can show `revision 0 → 1`.
- Separate admission, queue, dispatch, publication, stage, snapshot, render, and send duration fields.
- `StageSnapshot` and `DeliverySnapshot`.
- Command-specific delivery field accessors.
- Failure category. Prefer a generic `failed` status; retaining the current sanitized failure summary would require an additional optional generic note field and should be justified separately.

Current specialized fields are concentrated at `tuna/tuna/private/profiler.ss:107-144` and `tuna/tuna/private/profiler.ss:250-288`, making an in-place private migration practical.

## Koyo-inspired rendering

Koyo’s useful transferable ideas are:

- small parent-linked timing records: `/home/jay/Code/koyo/koyo-lib/koyo/profiler.rkt:43-81`;
- unwind-safe dynamic nesting: `/home/jay/Code/koyo/koyo-lib/koyo/profiler.rkt:120-146`;
- disabled execution of the original body: `/home/jay/Code/koyo/koyo-lib/koyo/profiler.rkt:148-159`;
- recursive timing rendering: `/home/jay/Code/koyo/koyo-lib/koyo/profiler.rkt:176-206`;
- nested disclosure styling: `/home/jay/Code/koyo/koyo-lib/blueprints/standard/resources/css/_uprofiler.scss:55-125`;
- instrumentation at useful subsystem boundaries, including nested database work: `/home/jay/Code/koyo/koyo-lib/koyo/database.rkt:83-115`.

Do not transfer its database collector, inline statement JavaScript, request-scoped middleware, or thread parameter as cross-thread correlation. Koyo’s root is synchronous HTTP middleware: `/home/jay/Code/koyo/koyo-lib/koyo/profiler.rkt:261-266`; Tuna’s command and delivery lifecycle crosses independently owned threads.

Render recursively in linear time from nested snapshots:

```html
<aside id="tuna-profiler">
  <details id="tuna-profiler-panel" data-preserve-attr="open">
    <summary>changed · keydown i / KeyI · total 130 µs</summary>
    <ol class="tuna-profiler__tree">
      <li>
        <details id="tuna-profiler-node-12-4"
                 data-preserve-attr="open">
          <summary>
            <span>transition</span>
            <code>tuna-dispatch</code>
            <span>self 20 µs</span>
            <span>total 90 µs</span>
          </summary>
          …
        </details>
      </li>
    </ol>
  </details>
</aside>
```

Use stable IDs derived only from validated profile-generation/node integers. Keep the panel ID stable across profiles; node IDs remain stable for the life of a profile, allowing late delivery updates to preserve disclosure state. New command generations may intentionally reset node-level disclosure while preserving the overall panel.

## Disclosure state: `data-preserve-attr`, not signals

Datastar’s documentation describes `data-preserve-attr` specifically as preserving an attribute while morphing and uses `<details open data-preserve-attr="open">` as its example.

Pinned v1.0.2 source confirms:

- outer and inner modes call the morph algorithm: upstream `library/src/plugins/watchers/patchElements.ts@e24f04d:228-261`;
- matching IDs are preserved and moved rather than blindly replaced: `patchElements.ts@e24f04d:302-339`, `395-418`;
- the preservation list is read from the **incoming** node: `patchElements.ts@e24f04d:567-600`;
- preserved attributes are skipped during property changes, setting, and removal: `patchElements.ts@e24f04d:602-617`, `658-671`.

Therefore every incoming panel/node `<details>` must include `data-preserve-attr="open"`. Native user toggling updates the reflected `open` attribute, and later profiler outer morphs retain it.

Signals are inferior here: they require per-node names, initialization and cleanup rules, binding `open` to reactive state, and potentially expose UI state in Datastar signal payloads. They add schema and lifecycle without improving native disclosure.

Tuna’s committed asset is the exact v1.0.2 release artifact at commit `e24f04d43ca4445d662b4a035e5bfe9ed68de57c`, SHA-256 `2837d87acf6ee0ba8e4e63765926c25a98d63883b02f88be194a86b81d3fd24a`: `tuna/tuna/web/README.md:1-18`.

## Flame chart

**Do not add one now.**

A correct flame chart would require absolute offsets, overlap rules, asynchronous lanes, scaling, and substantially more CSS/SVG or executable browser interaction. Async delivery can begin after the command root closes, so a conventional contained flame layout would be misleading. The recursive tree with self and inclusive time answers the immediate performance questions and matches Koyo’s proven scope.

Retain ticks internally only where already required; do not publish timeline offsets merely for a hypothetical future chart.

## Compatibility and migration

The profiler implementation is currently private and uncommitted. The only intentional public profiler surface is `tuna-profiler-enabled`; the public runtime façade must remain unchanged. Therefore:

1. Refactor `private/observation.ss`, `private/profiler.ss`, and `private/profiler-render.ss` in place.
2. Replace private specialized accessors and their tests rather than deprecating them.
3. Preserve:
   - one live enable read per decoded admission;
   - process-wide latest-only behavior;
   - fixed route and independent stream;
   - coherent state-root provenance;
   - command completion/readiness ordering;
   - 64-stream and 64-delivery bounds;
   - supersession rules;
   - fail-open clock/store/finalizer behavior;
   - disconnect and shutdown behavior;
   - absence of profiler feedback.
4. Keep profile rendering outside all instrumentation entry points.
5. Do not change `:tuna/lib/runtime` exports or ordinary `function-ref` identity behavior.

The current public behavior is documented at `tuna/tuna/README.md:37-57`. Existing coordinator and runtime concurrency guarantees remain valuable and are extensively tested at `tuna/tuna/test/profiler-test.ss:400-640` and `tuna/tuna/test/server-runtime-test.ss:530-858`.

## Tests

Update or add deterministic coverage for:

1. Generic nested builders and snapshots, stable ordering, close-once behavior, and immutable published views.
2. Exact fake-clock inclusive/self durations; asynchronous children excluded from parent self.
3. Automatic direct `defun`, `defaction`, and `deftransition` nesting.
4. Central action/transition runtime invocation without duplicate spans.
5. Live redefinition still selecting exactly one current implementation.
6. Public function arity, capture, event, documentation, result, and exception compatibility.
7. Inherited child threads producing no synchronous span.
8. Changed, unchanged, failed, full, and not-running tree shapes.
9. Exact revision provenance and coalesced wake attribution.
10. Delivery tree shape: snapshot, render, automatic `tuna-render-state`, and send.
11. Multiple subscriber deliveries as asynchronous siblings.
12. Existing 64-slot omission and supersession behavior.
13. Recursive escaping, empty state, no removed table metadata, and no inline script.
14. Stable generated IDs and `data-preserve-attr="open"` on all disclosure elements.
15. Rendered markup containing no `data-signals`, `data-bind`, or command-specific client state.
16. Existing profiler route, independent stream, fault containment, shutdown, and feedback tests.

## Validation commands

Focused:

```sh
cd /home/jay/Code/workbench-gerbil/tuna/tuna
gerbil test -v 0 \
  ./test/profiler-test.ss \
  ./test/state-runtime-test.ss \
  ./test/server-runtime-test.ss \
  ./test/server-protocol-test.ss \
  ./test/event-test.ss \
  ./test/documentation-test.ss
```

Source, compiled, and optimized parity:

```sh
cd /home/jay/Code/workbench-gerbil/tuna/tuna
timeout --signal=TERM --kill-after=10s 30m \
  test/run-command-runtime-matrix.sh
```

Full authoritative gate:

```sh
cd /home/jay/Code/workbench-gerbil
ESBUILD=/home/jay/.nix-profile/bin/esbuild \
  tuna/tuna/test/run-server-runtime-validation.sh
```

Final read-only checks:

```sh
git -C /home/jay/Code/workbench-gerbil/tuna diff --check
git -C /home/jay/Code/workbench-gerbil/tuna diff --cached --check
git -C /home/jay/Code/workbench-gerbil/tuna status --short
```

These commands come from `plans/tuna-profiler/spec.md:152-174`, `tuna/tuna/test/run-command-runtime-matrix.sh:1-130`, and `tuna/tuna/test/run-server-runtime-validation.sh:1-136`.

## Residual risks and confidence

- **Medium:** hygienically exposing a private span helper through the existing live-binding macros must be verified in source, compiled, and optimized modes.
- **Medium:** node identity across repeated/reordered identical calls needs explicit integer IDs; description-derived IDs are unsafe.
- **Medium:** self time assumes exact same-thread nesting for synchronous children. Defensive clamping is still needed for clock failures.
- **Medium:** removing failure summaries and fixed revision rows changes current private/protocol assertions and should be explicitly reflected in the revised product contract.
- **Low:** node-level disclosure resets on a new command generation; the overall panel remains preserved.
- **Low:** recursive rendering depth is bounded by actual live-call depth and the existing 64 detailed-delivery limit, but pathological recursion should remain bounded by retained profile policy.

**Confidence:** high for the data model, synchronous/async distinction, Datastar disclosure mechanism, Koyo comparison, and preservation of Tuna’s current concurrency semantics; medium-high for the exact automatic live-function wrapper placement pending implementation-level arity and macro-expansion tests.