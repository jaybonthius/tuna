# Immediate-mode GUIs, Compose, SwiftUI/Xilem and the Lisp lineage: prior art for ADR 17

Research, 2026-10-22. Read-only; no repository file edited. Labels: **Fact** (read in the cited source or code), **Interp** (my reading of what a source implies), **Inference** (my recommendation for Tuna; no source states it). Tuna is cited at `main` `17c9315`. Pinned upstream commits: Dear ImGui `4be0b47`, egui `bf5ac0d`, Clay `e6cc369`, Xilem `271a27a`, McCLIM `c5bc6cb`, Lem `48b809b`. This complements `incremental-prior-art.md` and `text-rendering-prior-art.md` and does not repeat them.

## Summary

Every system surveyed confirms ADR 17's core: an identity per piece, reuse while the inputs are unchanged, equality cutoff on derived values, value-compared lines, and a cache swept by "used last frame". None of them contradicts automatic read recording. Compose and SwiftUI's Observation do exactly that, and they reached it after hand-written keys (CLIM's `:cache-value`, Genera's `with-redisplayable-output`, React-style props) proved error-prone.

They also expose four hazards that ADR 17 does not yet name. Each has already bitten Tuna or a sibling system:

1. **Captured values.** A `memo` thunk that closes over a value computed outside it is reused with stale captures. McCLIM documents the problem and Xilem forbids capturing closures at compile time.
2. **Side outputs during drawing.** Anything a piece writes besides its HTML is lost when the piece is reused. Compose bans it. Tuna's renderer does it today (line-id pinning), and this is the root of the audit's "line ids dropped under reused ancestors" bug.
3. **Ambient context.** Dynamic parameters such as `rendering-view` are inputs that read recording does not see. McCLIM checks only the cursor x position and leaves an "XXX" note.
4. **Measurement feedback loops.** egui and Compose both document render → measure → render cycles. egui rounds widths to integers to stop them.

**Recommendation (Inference):** keep ADR 17 and add four rules:
- a thunk takes its non-source inputs as an explicit, `equal?`-compared argument;
- drawing has no side outputs, or they are stored with the piece and replayed;
- dynamic parameters read while drawing are sources or key parts;
- client measurements are quantized sources with cutoff.

Also make DOM ids derive from explicit identity, and keep reused children marked live.

## 1. Immediate-mode GUI libraries

**Dear ImGui.**
- **Identity.** **Fact:** "Unique identifiers are hashes of the label + of the parent scope". `PushID()` adds a pointer, string or integer to the ID stack. "Using the same label+ID is the most common user mistake!" ([FAQ L283–294](https://github.com/ocornut/imgui/blob/4be0b47ecc0edd535a40a79f6ceb6f1ac5936483/docs/FAQ.md#L283-L294)).
- **Dependencies and skipping.** None are tracked. The UI is "fully issued on every update". The library "stores minimal amounts of data" and is "optimized for the worst case" ([FAQ L96–106](https://github.com/ocornut/imgui/blob/4be0b47ecc0edd535a40a79f6ceb6f1ac5936483/docs/FAQ.md#L96-L106)).
- **What it caches.** **Fact:**
  - per-ID widget state in `ImGuiStorage`, sorted pairs where "a typical frame shouldn't need to insert any new pair";
  - unused window and table buffers, freed after `ConfigMemoryCompactTimer` (60 s);
  - glyphs in an atlas, plus per-glyph advances because `CalcTextSize` is "often bottleneck in large UI".

  `ImGuiListClipper` virtualizes long lists. Sources: [imgui.h L2505](https://github.com/ocornut/imgui/blob/4be0b47ecc0edd535a40a79f6ceb6f1ac5936483/imgui.h#L2505), [L2842–2870](https://github.com/ocornut/imgui/blob/4be0b47ecc0edd535a40a79f6ceb6f1ac5936483/imgui.h#L2842-L2870), [L3978](https://github.com/ocornut/imgui/blob/4be0b47ecc0edd535a40a79f6ceb6f1ac5936483/imgui.h#L3978).
- **Interp.** Text layout is recomputed on every call; only the glyphs are cached. ImGui's lesson is identity hygiene, not skipping. A position-derived identity (a loop index) collides or shifts silently.

**egui.**
- **Identity.** Widgets are identified by `Id`; `check_for_id_clash` warns at runtime when two widgets share one ([context.rs L1432](https://github.com/emilk/egui/blob/bf5ac0dac137af9a4861611f3d2a77ad531f50e3/crates/egui/src/context.rs#L1432)).
- **Retained state.** `Memory::data` stores "superficial state" by `Id`: collapsed headers, scroll offsets and cursors. It is "NOT meant to store any important data" ([memory/mod.rs](https://github.com/emilk/egui/blob/bf5ac0dac137af9a4861611f3d2a77ad531f50e3/crates/egui/src/memory/mod.rs)).
- **Caches.** **Fact:**
  - `FrameCache` hashes a key and keeps a value "if it is still used next frame"; anything not used is evicted in `evict_cache` ([frame_cache.rs](https://github.com/emilk/egui/blob/bf5ac0dac137af9a4861611f3d2a77ad531f50e3/crates/egui/src/cache/frame_cache.rs)).
  - The galley (text layout) cache hashes the whole `LayoutJob` plus `pixels_per_point`. It splits large jobs into paragraphs, "so if we edit a single paragraph, only that paragraph will be re-layouted". When a parent galley hits, it marks every child paragraph used, so the children are not evicted ([galley_cache.rs L66–86](https://github.com/emilk/egui/blob/bf5ac0dac137af9a4861611f3d2a77ad531f50e3/crates/epaint/src/text/galley_cache.rs#L66-L86); `flush_cache` at [L249–256](https://github.com/emilk/egui/blob/bf5ac0dac137af9a4861611f3d2a77ad531f50e3/crates/epaint/src/text/galley_cache.rs#L249-L256)).
- **Failure modes egui documents.** **Fact:**
  1. *Shared eviction generation.* Independently scheduled viewports that shared one galley cache would "continuously evict one another's working sets". egui now keeps one layout cache per viewport ([fonts.rs L27–33](https://github.com/emilk/egui/blob/bf5ac0dac137af9a4861611f3d2a77ad531f50e3/crates/epaint/src/text/fonts.rs#L27-L33), [L82–87](https://github.com/emilk/egui/blob/bf5ac0dac137af9a4861611f3d2a77ad531f50e3/crates/epaint/src/text/fonts.rs#L82-L87)).
  2. *Measurement feedback.* A wrap width of 196.0 came back as 195.9997, re-wrapped to 185 and kept cycling. egui rounds `max_width` to integers, citing issues #4927, #4928, #5084 and #5163 ([galley_cache.rs L42–63](https://github.com/emilk/egui/blob/bf5ac0dac137af9a4861611f3d2a77ad531f50e3/crates/epaint/src/text/galley_cache.rs#L42-L63)).
  3. *First-frame jitter.* A `Grid` guesses column widths from the previous frame and calls `request_discard` to run another pass ([lib.rs L207–223](https://github.com/emilk/egui/blob/bf5ac0dac137af9a4861611f3d2a77ad531f50e3/crates/egui/src/lib.rs#L207-L223)).
- **Repaint on demand.** "egui only repaints when there is interaction … or an animation, so if your app is idle, no CPU is wasted". `request_repaint` coalesces requests and may come from other threads ([README L234](https://github.com/emilk/egui/blob/bf5ac0dac137af9a4861611f3d2a77ad531f50e3/README.md?plain=1#L234); [context.rs ~L2116–2128](https://github.com/emilk/egui/blob/bf5ac0dac137af9a4861611f3d2a77ad531f50e3/crates/egui/src/context.rs#L2116-L2128)).

**Clay.**
- **Identity.** Elements are identified by hashed string ids (`CLAY_ID`, and `CLAY_IDI` with an index offset).
- **Text cache.** Text measurements are cached by word. **Fact:** the cache "may be incorrect" if measurement "can depend on external factors that clay does not know about, like DPI changes". The user must then call `Clay_ResetMeasureTextCache` ([README L653–657](https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/README.md?plain=1#L653-L657)).
- **Retained renderers.** Clay suggests mapping element ids to persistent objects and simply comparing "the memory of two render commands with matching IDs" to find dirty elements. Its HTML renderer works this way ([L523–530](https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/README.md?plain=1#L523-L530)).
- **Interp.** This is per-item value comparison, the same as ADR 17's lines. The DPI note is an untracked input, which is exactly what Tuna's per-client measurement sources prevent.

## 2. Jetpack Compose

- **Identity: positional memoization.** **Fact:**
  - An instance "is identified by its call site". Calls repeated from one call site are told apart by execution order, so inserting at the top "will cause a recomposition in all `MovieOverview` calls whose input parameter has changed position" and restarts their effects.
  - `key(movie.id) { … }` gives explicit identity, which only has to be unique among siblings.

  Source: [Lifecycle of composables](https://developer.android.com/develop/ui/compose/lifecycle). The Composer stores groups in a gap-buffer slot table ([How Composition Works](https://android.googlesource.com/platform/frameworks/support/+/HEAD/compose/runtime/design/how-compose-works.md)).
- **Dependencies: automatic.** **Fact:**
  - Snapshot state reports every read to a read observer, "no matter how deep in the call stack they occur" ([Klippenstein, Snapshot system](https://blog.zachklipp.com/introduction-to-the-compose-snapshot-system/)).
  - Reads are tracked per phase (composition, layout, draw). A read in the draw phase reruns only drawing ([Phases](https://developer.android.com/develop/ui/compose/phases)).
  - Writes of an equal value are de-duplicated under the default `structuralEqualityPolicy`. `neverEqualPolicy` exists for mutable objects held in state.
- **Skipping.** **Fact:** a restartable composable is skipped when all of its parameters compare equal.
  - A type is *stable* only if `equals` is forever consistent, every change to a public property notifies composition, and every property is stable.
  - Strong skipping, the default since Kotlin 2.0.20, compares unstable parameters with `===` and stable ones with `equals`.
  - It also wraps every lambda in `remember`, keyed by the lambda's captured variables.
  - Large collections in `@Stable` models make equality checks expensive.

  Sources: [Lifecycle](https://developer.android.com/develop/ui/compose/lifecycle), [Strong skipping](https://developer.android.com/develop/ui/compose/performance/stability/strongskipping).
- **Cutoff.**
  - `derivedStateOf` (and `computedStateOf` from Runtime 1.13) invalidates readers only when its output changes. Its documented use is fast inputs feeding slow outputs, such as scroll offset → "past the first item". Wrapping a plain combination of two states in it is "purely overhead".
  - `produceState` "conflates; setting the same value won't trigger a recomposition".

  Sources: [Best practices](https://developer.android.com/develop/ui/compose/performance/bestpractices), [Side effects](https://developer.android.com/develop/ui/compose/side-effects).
- **Pitfalls Compose documents.** **Fact:**
  1. Composables must be "idempotent, and side-effect free". Composition may be skipped, cancelled, run in parallel or run in any order. The `ListWithBug` example counts items in a local variable during composition and shows a wrong count ([Thinking in Compose](https://developer.android.com/develop/ui/compose/mental-model)).
  2. *Backwards writes* (writing state after reading it during composition) cause endless recomposition ([Best practices](https://developer.android.com/develop/ui/compose/performance/bestpractices)).
  3. *Cross-frame loops.* `onSizeChanged` → state → padding leaves the frame wrong for one frame and can repeat ([Phases](https://developer.android.com/develop/ui/compose/phases)).
  4. Effects belong in `SideEffect` ("after every successful recomposition"), or in `LaunchedEffect` and `DisposableEffect`, which are keyed by every variable the effect uses ([Side effects](https://developer.android.com/develop/ui/compose/side-effects)).
  5. Reading fast-changing state high in the tree recomposes the whole subtree. The fix is to defer the read into a lambda or a later phase.

## 3. SwiftUI and Xilem

**SwiftUI.**
- **Identity.** **Fact:** identity is either *explicit* (`id`, or `ForEach` over `Identifiable` items) or *structural* (type and position in the generic view type). An `if` gives each branch a distinct identity and resets its state. `AnyView` erases structure. Indices and random ids "are not a stable form of identity"; identifiers must be stable and unique. State lifetime equals identity lifetime ([Demystify SwiftUI, WWDC21](https://developer.apple.com/videos/play/wwdc2021/10022/)).
- **Dependencies.** A dependency graph invalidates only the views that depend on what changed. View values are compared so that bodies are not regenerated needlessly ("Because views are value types, SwiftUI can efficiently compare them").
  - `@Observable` records each property access per instance while `body` runs. A change to an unread property does not invalidate the view.
  - A computed property not built from stored properties needs manual `access` and `withMutation` calls ([Discover Observation, WWDC23](https://developer.apple.com/videos/play/wwdc2023/10149/)).
- **`EquatableView`.** It "compares itself against its previous value and prevents its child updating if its new value is the same" ([Apple docs](https://developer.apple.com/documentation/swiftui/equatableview); page is JavaScript-rendered, text confirmed via a mirror).
- **AttributeGraph.** It is a private framework, known only through reverse engineering ([Rens Breur](https://rensbr.eu/blog/swiftui-attribute-graph/)). **Confidence:** low for any claim about its internals.

**Xilem (Raph Levien).**
- **Architecture.** **Fact:** a view tree is rebuilt on every change and diffed against the previous one (`rebuild`). At most two view trees exist at once. Identity is structural or an explicit key, "as in SwiftUI". Events route by *id path*. `Memoize` "takes a data value (which supports both `Clone` and equality testing) and a closure", like Elm's `Html.Lazy`, with `Arc::ptr_eq` for large data ([Xilem: an architecture for UI in Rust, 2022](https://raphlinus.github.io/rust/gui/2022/05/07/ui-architecture.html)).
- **No captures in `Memoize`.** Today's implementation rejects capturing closures at compile time (`assert!(size_of::<InitView>() == 0)`). The stated reason: a closure with captured context "potentially messes up the logic of memoize", because a changed capture would not be noticed ([memoize.rs L34–40, L68–70, L126](https://github.com/linebender/xilem/blob/271a27a6d4a930f7878d404f9014e3c50a3a9b88/xilem_core/src/views/memoize.rs#L34-L70)).
- **Framing.** Levien's 2019 post frames reactive UI as a pipeline of incremental tree transformations, where "tracking dependencies … probably accounts for most of the variation between frameworks" ([Towards a unified theory of reactive UI](https://raphlinus.github.io/ui/druid/2019/11/22/reactive-ui.html)).

## 4. The Lisp lineage

**CLIM `updating-output` (CLIM 2 specification, chapter 21).** **Fact:**
- **Signature and behavior.** `(updating-output (stream &key unique-id (id-test #'eql) cache-value (cache-test #'eql) fixed-position all-new parent-cache record-type) &body)`. When `cache-value` matches the stored value under `cache-test`, "the code in body is not run".
- **Unique ids.**
  - A `unique-id` need only be unique among the children of the enclosing cache, "like using a telephone area code".
  - An id with no `cache-value` is "never valid; its children always have to be checked".
  - A `cache-value` with no id gets sequential ids, which is positional.
- **Hand-propagated ticks.** The spec advises giving parents their own modification tick, propagated up by hand, so whole branches can be skipped. That is a hand-written key.

Sources: [21.1](http://metamodular.com/CLIM-spec/21-1.html), [21.2](http://metamodular.com/CLIM-spec/21-2.html). An editor's note on 21.3 calls the protocol "itself a disaster" ([21.3](http://metamodular.com/CLIM-spec/21-3.html)).

**McCLIM's implementation.** **Fact:**
- **Only the root closure reruns.** The children's closures are never called directly, "because any free variables captured in the UPDATING-OUTPUT forms need to see the fresh bindings from this run of the code" ([redisplay.lisp L33–36](https://github.com/McCLIM/McCLIM/blob/c5bc6cb7f03ce0d77211403642caa1e3e8f963d0/Core/extended-output/incremental-redisplay/redisplay.lisp#L33-L36)).
- **States.** A record whose cache value matches is marked `:clean` together with its subtree, or `:moved`. Records never visited are deleted from their parent caches, which is mark and sweep.
- **Layout touching clean children.** A table that lays out clean children afterwards must re-dirty them through an `:around` method ([L39–69](https://github.com/McCLIM/McCLIM/blob/c5bc6cb7f03ce0d77211403642caa1e3e8f963d0/Core/extended-output/incremental-redisplay/redisplay.lisp#L39-L69)).
- **Ambient state.** Reuse also requires `state-matches-stream-p`, but that compares only the cursor x position. A comment marked "XXX" asks whether more graphics state should be tested ([updating-record.lisp L61–77](https://github.com/McCLIM/McCLIM/blob/c5bc6cb7f03ce0d77211403642caa1e3e8f963d0/Core/extended-output/incremental-redisplay/updating-record.lisp#L61-L77)).
- **Interp.** A change of ink or text style around a clean record is not detected.

**Symbolics Genera Dynamic Windows.** **Fact:**
- `dw:with-redisplayable-output` has the same `:unique-id` and `:cache-value` pair. `dw:independently-redisplayable-format` caches each format argument separately.
- For state that changes asynchronously between redisplay passes, a variable used as `:cache-value` is snapshotted in a closure "during the first pass … on both passes".

Source: *Programming the User Interface*, Genera 8, §9.1 and §9.5, pp. 281–293 ([PDF](https://www.chai.uni-hamburg.de/~moeller/symbolics-info/documentation/Programming-the-User-Interface.pdf)). CLIM inherited this design.

**Lem (Common Lisp editor).**
- **Line caches.** **Fact:**
  - Each window keeps a drawing cache keyed by **screen row y**. A row is skipped when its height and its reduced list of drawing objects are `drawing-object-equal` ([physical-line.lisp L365–421](https://github.com/lem-project/lem/blob/48b809b2f7c6346936950844f26f23337370c58a/src/display/physical-line.lisp#L365-L421)).
  - A line-fingerprint cache hashes the line string, attributes, overlays, scroll start and left margin, and compares hashes only ([L536–557](https://github.com/lem-project/lem/blob/48b809b2f7c6346936950844f26f23337370c58a/src/display/physical-line.lisp#L536-L557)).
- **Bugs recorded in its comments.** **Fact:**
  1. `sxhash` on CLOS objects is identity-based, so "an attribute mutated in place" kept its hash and produced "stale glyphs (ghosting)". It was fixed with content hashing ([L459–475](https://github.com/lem-project/lem/blob/48b809b2f7c6346936950844f26f23337370c58a/src/display/physical-line.lisp#L459-L475)).
  2. Rows blanked by `clear-to-end-of-window` kept cache entries. Undoing a large deletion then matched the stale entry, skipped the render, and left rows blank ([L397–406](https://github.com/lem-project/lem/blob/48b809b2f7c6346936950844f26f23337370c58a/src/display/physical-line.lisp#L397-L406)).
- **Frontends.** **Fact:** the frontend protocol is generic functions on an implementation object (`lem-if:render-line`, `clear-to-end-of-window`, `update-display`; [interface.lisp L181–186](https://github.com/lem-project/lem/blob/48b809b2f7c6346936950844f26f23337370c58a/src/interface.lisp#L181-L186)).
  - The server frontend sends JSON-RPC over WebSocket. Each changed row becomes a `clear-eol` plus a put notification. These are queued and sent as one `bulk` broadcast per `update-display` to every client ([server/main.lisp L150–161](https://github.com/lem-project/lem/blob/48b809b2f7c6346936950844f26f23337370c58a/frontends/server/main.lisp#L150-L161), [L411–437](https://github.com/lem-project/lem/blob/48b809b2f7c6346936950844f26f23337370c58a/frontends/server/main.lisp#L411-L437), [L728–735](https://github.com/lem-project/lem/blob/48b809b2f7c6346936950844f26f23337370c58a/frontends/server/main.lisp#L728-L735)).
  - The browser draws onto a canvas (`fillText` in `frontend/editor.js`). The webview frontend is that same JSON-RPC class inside a native webview ([webview/main.lisp](https://github.com/lem-project/lem/blob/48b809b2f7c6346936950844f26f23337370c58a/frontends/webview/main.lisp)).
- **Interp.**
  - Lem sends cell or row patches, not HTML, and all clients share one display size. Tuna's per-client pieces and fat morph are a different design.
  - Lem's y-keyed cache redraws every row below an inserted line. ADR 17's value-keyed lines avoid that.

**Morphic (Squeak) and Bloc.**
- **Morphic.** A morph reports damage with `invalidRect:`/`changed`. The world redraws the damaged rectangles each cycle. The damage recorder is single-threaded: background threads must use `WorldState addDeferredUIMessage:` ([Squeak wiki 226](https://wiki.squeak.org/squeak/226)). A 2000 squeak-dev thread observes redraws up to 50 times a second from `step` polling ([list post](http://lists.squeakfoundation.org/pipermail/squeak-dev/2000-March/003488.html)). This is invalidation declared by hand at the pixel level.
- **Bloc (Glamorous Toolkit).** A retained `BlElement` tree with explicit invalidation and layout requests, driven by a space's frame loop ([GT book](https://book.gtoolkit.com/bloc-elements-4qiu6wdwt3q83ef2idikrcz47)). **Confidence:** low; only secondary documentation was read.

## Does this change ADR 17?

Each point is **Inference** unless marked otherwise.

1. **Automatic recording: confirmed.**
   - Compose snapshots and SwiftUI Observation record reads automatically, through any call depth.
   - CLIM, Genera and Morphic require hand-declared validity (`cache-value`, modification ticks propagated by hand, `invalidRect:`). The CLIM spec itself tells programmers to propagate ticks up manually, which is the drift ADR 17 rejects.
   - Observation's manual `access`/`withMutation` escape hatch for computed properties corresponds to Tuna's outside sources stamping through their contract.
2. **Change: make captured inputs explicit.** Compose compares parameters and keys remembered lambdas by their captures. McCLIM never reruns child closures because of stale captures. Xilem forbids captures outright. In ADR 17, `(memo key thunk)` checks only recorded source reads. A thunk that closes over a value its parent computed (a column count, a face list, a flag) would be reused with the old value after the parent reruns. **Recommendation:**
   - write the form as `(memo key inputs thunk)`, where `inputs` is compared with `equal?` (CLIM's `cache-value`/`cache-test`, with `equal?` as the test);
   - the thunk receives `inputs` and has no other free non-source values;
   - the plan's "items whose inputs are values" already fits this shape.

   The double-render test catches violations, but only on paths the tests exercise.
3. **Change: no side outputs from drawing, or replay them.**
   - **Fact (Tuna):** the renderer writes `drawing-pinning` during drawing (`pin-line-run!`, `plugins/renderer/plugin.ss` L216–230 at `17c9315`; local repository, no public permalink).
   - **Fact (Tuna):** it then walks reused subtrees to copy their entries forward ("descendants of reused HTML included", L486–496). This is the workaround behind the audit's line-id bug.
   - **Compose:** side effects in composition are forbidden, and Compose's `ListWithBug` example shows the bug class.
   - **Recommendation:** a piece's result is `(html . side-outputs)`, and reuse replays both. Better still, move pinning out of drawing into a source owned by the view. Extend the test mode to fail any write to a renderer-global table, not just to sources.
4. **Change: ambient context is an input.**
   - **Fact (Tuna):** renderers read the dynamic parameters `rendering-view` and `rendering-lines` (plugin.ss L127–131).
   - McCLIM's ambient check is incomplete, and SwiftUI's `Environment` is a tracked dependency.
   - **Recommendation:** every parameter read while drawing is either a source (recorded by its accessor) or part of `key`/`inputs`. "A piece that read a per-client source belongs to that client" then also covers parameters such as the current view.
5. **Identity: confirms explicit identity; add a rule for DOM ids.** ImGui, Compose, SwiftUI and Xilem all warn that positional or index identity shifts or collides. Compose restarts effects when position changes; SwiftUI resets state. **Recommendation:**
   - `memo` keys and DOM ids come from explicit identity (node id, line identity through the pinned offset, row key), never from position or a sequential counter;
   - make duplicate keys under one parent an error in test mode, like egui's id-clash warning and ImGui's documented mistake;
   - deterministic ids also keep the double-render comparison free of false failures.
6. **Equality cutoff: confirmed, with a warning on cost.**
   - Supporting evidence: `derivedStateOf`/`computedStateOf`, `produceState` conflation, equal writes de-duplicated under `structuralEqualityPolicy`, `EquatableView`, Xilem `Memoize`.
   - Compose warns that `equals` on large collections can cost more than recomputing. **Recommendation:** use cutoff at leaves (lines, rows, attributes) and on fast→slow derivations, not on whole-buffer values.
   - Lem's ghosting bug shows that cutoff must compare **content**. A mutable object compared by identity, or a hash, misses in-place mutation. `equal?` on Gerbil structs that are mutated in place has the same trap; Compose calls this "stability".
7. **Mark and sweep: confirmed, with two details.** egui's `FrameCache` and galley cache, and McCLIM's deletion of unvisited records, use the same "used last frame" sweep. Two lessons apply directly:
   - **(a)** keep the sweep generation **per client**, because clients render on independent schedules (egui's per-viewport fix). The ADR's wording "the last frame of some client" implies this; state it.
   - **(b)** reusing a parent must mark its unvisited descendant pieces live (egui marks child paragraphs). Otherwise a sweep evicts children that the next partial invalidation needs.
8. **Measurements: add cutoff and quantization.** Client measurements are a source, so render → measure → render is the cross-frame loop that Compose and egui document. **Recommendation:** quantize measurements (integer pixels or cells, as egui rounds widths), compare them with cutoff, and note in the ADR that a renderer must not derive a measurement request from its own previous output in the same frame. Clay's DPI note shows why measurements must be sources rather than hidden inputs; ADR 17 already does this.
9. **Idle and outside state: confirmed.**
   - egui repaints only on interaction or `request_repaint`. Morphic's 50 Hz stepping is the counterexample. Morphic and Genera require background updates to be posted to the UI thread, or snapshotted per pass, exactly as ADR 17's jobs post differences to the editor thread.
   - Because drawing runs on one thread with no source writes, Tuna does not need Genera's two-pass snapshotting.
10. **Phases: optional addition.** Compose's lesson is that a read in the wrong phase widens invalidation. Tuna's analog (**Inference**): a position-only change, such as scroll offset or cursor blink, should be read in the smallest piece or sent as a signal-free attribute, not read by the view piece. This matches the plan's "point becomes an input of its line".

**No source contradicts ADR 17's direction.** The one design that differs is Lem: a row-patch protocol over JSON-RPC, a single shared display, and canvas rendering. It is a valid alternative that ADR 7/13's fat morph already excluded, so it is not evidence against `memo`.

## Missing evidence

- SwiftUI's AttributeGraph internals, and whether `@Observable` de-duplicates writes of equal values, were not verified from primary sources.
- Dear ImGui's per-frame text cost was not measured; that text layout is uncached is my interpretation of the headers.
- Genera was read in the 1990s-era manual (Feb 2018 reprint), not its source.
- Bloc was read only in secondary documentation.
- Lem's `redraw-buffer` was read only around the caches; the full frame scheduling was not traced.

## Sources

- **Kept:**
  - Dear ImGui FAQ and imgui.h (identity, retained state);
  - egui source (frame and galley caches, per-viewport eviction, rounding loop, repaint);
  - Clay README (measurement cache, retained HTML renderer);
  - Android Compose docs: lifecycle, strong skipping, mental model, phases, best practices, side effects;
  - Klippenstein's Snapshot post (read observer, de-duplicated writes);
  - Apple WWDC21 *Demystify SwiftUI* and WWDC23 *Discover Observation*;
  - Levien 2019/2022 and Xilem `memoize.rs`;
  - CLIM 2 specification ch. 21;
  - McCLIM incremental-redisplay source;
  - Genera *Programming the User Interface* §9;
  - Lem `physical-line.lisp`, `interface.lisp` and the server/webview frontends;
  - Squeak wiki 226;
  - Tuna `plugins/renderer/plugin.ss` at `17c9315`.
- **Deprioritized:**
  - DeepWiki pages on Bloc (machine-generated);
  - Zenn and blog reverse-engineering of AttributeGraph (secondary);
  - the bitsavers Genera PDF (HTTP 403; used a mirror).

## Next steps

- Before the plan's step 2, decide the `memo` signature (`key`, `inputs`, `thunk`) and how pinning and other side outputs are stored and replayed.
- In the double-render test mode, also fail on duplicate sibling keys and on writes to renderer-global tables.
