# Incremental `UI = f(state)`: prior art and a model for Tuna

Research, 2026-10-22. Read-only; no repository file edited. Labels: **Fact** (read in the cited source or code), **Inference** (my reasoning), **Unverified** (not checked). Tuna code is cited at `main` `e972004`. Hyperlith is cited at `origin/master` `a8af42a`. The local `master` checkout is `34dbe2e`, which is older and predates the component cache. Emacs is cited at `541f693`.

## Summary

**Recommendation:** use **memo cells validated by revisions, with dependencies recorded automatically**. Glimmer's tags and Salsa's queries both work this way. Add **equality cutoff** at chosen cells (Salsa calls this "backdating"). Make external state a **source**: a cell whose revision changes only when a newly polled or watched value is not `equal?` to the old one.

This gives one recursive primitive, `(memo key thunk)`. It works the same for a layout container, a buffer node, a line, a decoration run, or a git-status section.

- **Validity check.** A cell is valid when no source it read during its last run has a newer revision than the snapshot it took then.
- **Leaf items** (lines, rows, cursors in a line) get their key from their small input **values**, not from positions. An inserted line therefore does not invalidate the lines after it.

Reference equality (Elm, React, Clojure `identical?`) only works when every input is a persistent value. Tuna's nodes are mutable and its text stores are not all persistent. Content hashing (Merkle trees, Unison) only pays off when equality must hold across processes or machines. Dirty flags and journals are what Tuna's per-node revisions already are. They are fast, but today the renderer must list every input by hand, and that list is where it goes wrong (TODO: "any rebind repaints every view").

## 1. Revision and tag autotracking

1. **Glimmer/Ember validators.**
   - **Claim:** there is one global counter, `$REVISION`. Writing a tag (`dirtyTag`) sets that tag's revision to `++$REVISION`. A combined tag's value is the maximum of its subtags. `validateTag(tag, snapshot)` is `snapshot >= tag[COMPUTE]()`. A cache (`createCache`/`getValue`) re-runs `fn` inside `beginTrackFrame`/`endTrackFrame` only when invalid. Every tag consumed during the run is combined into the cache's tag. The cache then *consumes its own tag*, so parent frames inherit its dependencies.
   - **Missing pieces:** there is no value-equality cutoff. `VOLATILE` (NaN) never validates. Dev builds assert against dirtying a tag that was already consumed in the same render, and against cycles.
   - **Sources:** [validators.ts](https://github.com/glimmerjs/glimmer-vm/blob/3c206686cea0c2dafad98eb4c3a8dc65cc572318/packages/%40glimmer/validator/lib/validators.ts), lines 29, 71–72; [tracking.ts `getValue`](https://github.com/glimmerjs/glimmer-vm/blob/3c206686cea0c2dafad98eb4c3a8dc65cc572318/packages/%40glimmer/validator/lib/tracking.ts), lines 143–187. **Support:** direct. **Confidence:** high.
   - **Cost (Inference):** a check costs O(number of tags read), and nested caches compose. The combined tag's max is memoized per `$REVISION`, so a valid subtree is skipped in O(1) amortized. Untracked reads are invisible, so the cache is stale (failure mode).
2. **Salsa (rust-analyzer).**
   - **Claim:** there is a global revision, bumped on every input set. Each query records the queries it read and "the revisions when their value last changed".
   - **Backdating:** a re-executed query whose result equals the previous result keeps its old changed-at revision. Dependents therefore stay valid (early cutoff).
   - **Durability:** inputs carry a durability level, and a version vector per durability lets Salsa skip whole subgraphs. Without durability, a change to `src/lib.rs` forced re-checking all stdlib queries, "about 300ms".
   - **Stated failure mode:** volatile details such as positions "sneaking in" defeat cutoff.
   - **Sources:** [Salsa algorithm](https://salsa-rs.github.io/salsa/reference/algorithm.html); [Durable incrementality](https://rust-analyzer.github.io/blog/2023/07/24/durable-incrementality.html). **Support:** direct. **Confidence:** high.
3. **Adapton (demanded computation graph).**
   - **Claim:** writes eagerly *dirty* edges backward from the changed ref. Reads (`force`) repair lazily, only what is demanded. An edge records the value its target returned. A thunk re-runs only if `edge.label ≠ target.value`, which is cutoff on value. Memo tables map arguments to prior traces and are held in weak hash tables.
   - **Costs:** 1.5–3.5× slower than eager incremental computation when everything is demanded, and roughly 2.7–14× the memory of from-scratch.
   - **Nominal Adapton** keys reuse by first-class **names** instead of arguments, to keep reuse across structural shifts.
   - **Sources:** [Hammer et al., PLDI 2014](http://matthewhammer.org/adapton/adapton-pldi2014.pdf); [Incremental Computation with Names](https://arxiv.org/abs/1503.07792). **Support:** direct for Adapton; abstract only for Nominal Adapton. **Confidence:** high / medium.
4. **Jane Street Incremental and Bonsai.**
   - **Claim:** a spreadsheet-like graph is fed by `Var.set` and recomputed by an explicit `stabilize`, and only observed nodes are kept live.
   - **Cost:** about 30 ns per node fired. The library is useful when node work is large relative to that overhead.
   - **Bonsai** compiles a UI (`Value.t`/`Computation.t`) into an Incremental graph. It offers `value_cutoff ~equal` for user-chosen equality cutoff, and omits `bind` so the graph can be analyzed statically.
   - **Failure mode:** reusing a `let%map` value duplicates its work.
   - **Sources:** [Introducing Incremental](https://blog.janestreet.com/introducing-incremental/); [Bonsai dynamism](https://bonsai.red/02-dynamism.html); [Bonsai.Incr](https://ocaml.org/p/bonsai/v0.16.0/doc/bonsai/Bonsai/Incr/index.html). **Support:** direct. **Confidence:** high.
5. **Skip.**
   - **Claim:** a reactive runtime keeps a directed graph of data and computations. It invalidates and re-evaluates computations when their inputs change, and keeps keyed `EagerCollection`s up to date. Your functions must obey stated invariants for this tracking to work.
   - **Sources:** [Skip: writing functions](https://skiplabs.io/docs/functions) and [EagerCollection](https://skiplabs.io/docs/api/core/interfaces/EagerCollection). I only saw search excerpts because the pages are JavaScript-rendered. **Support:** interpretation. **Confidence:** low–medium.
6. **Build Systems à la Carte (Mokhov, Mitchell, Peyton Jones).**
   - **Claim:** there are four rebuilders: dirty bit, verifying traces, constructive traces, and deep constructive traces.
     - **Verifying traces** "record the values/hashes of dependencies used last time".
     - **Constructive traces** also store the result, which allows sharing between users.
     - **Early cutoff:** do not run dependents when a result is unchanged. Make cannot do this.
     - **Minimality:** run a task only if it transitively depends on a changed input.
   - **Failure modes named:** untracked dependencies, non-determinism, volatile tasks (which "cannot be cached"), and Make's timestamps being fooled by `touch` or by clocks going backwards.
   - **Sources:** [paper PDF](https://www.microsoft.com/en-us/research/wp-content/uploads/2018/03/build-systems.pdf). **Support:** direct. **Confidence:** high.
   - **Inference:** a revision is a verifying trace whose "hash" is a monotonic integer. That is exact and cheap inside one process. Real hashes only matter when traces must outlive the process or be shared.

## 2. UI frameworks

1. **React.**
   - `memo` compares each prop with `Object.is`. A single "always new" prop breaks memoization. Deep comparison "can become incredibly slow". State and context bypass `memo`. Reconciliation matches children by position and `key`.
   - **Sources:** [memo](https://react.dev/reference/react/memo); [rendering lists](https://react.dev/learn/rendering-lists); [preserving state](https://react.dev/learn/preserving-and-resetting-state). **Support:** direct. **Confidence:** high.
2. **Elm `Html.Lazy`.**
   - It bundles a function with its arguments and skips the call when every argument "is equal by reference". This is sound because Elm functions are pure.
   - **Sources:** [Lazy.elm](https://raw.githubusercontent.com/elm/html/master/src/Html/Lazy.elm). **Support:** direct. **Confidence:** high.
   - **Inference:** this only works because all Elm state is persistent. A rebuilt-but-equal value misses the cache.
3. **Flutter.**
   - It keeps a list of dirty elements and jumps straight to them. An identical immutable widget (compared by object identity) cuts off the build. Layout cuts off when the constraints are unchanged. Children are reconciled per list by type and key; there is no tree diff.
   - **Sources:** [Inside Flutter](https://docs.flutter.dev/resources/inside-flutter). **Support:** direct. **Confidence:** high.
4. **Solid / Preact signals / Svelte 5.**
   - A read registers the running computation as a subscriber (Solid uses a `Set`; Preact uses linked `Node`s).
   - **Preact:** each signal has a **version number**, and a computed stores the versions it last saw. It bumps its own version only if its new value differs, which is early cutoff. It pushes "outdated" flags, but computeds are pulled lazily.
   - **Svelte 5:** uses write/read versions (`wv > reaction.wv` means dirty).
   - **Failure mode:** tracking is synchronous, so reads inside `setTimeout` are lost (Solid). Svelte 4's compile-time tracking broke under refactoring.
   - **Sources:** [Solid](https://docs.solidjs.com/advanced-concepts/fine-grained-reactivity); [Preact Signal Boosting](https://preactjs.com/blog/signal-boosting/); [Svelte runes](https://svelte.dev/blog/runes); [svelte 5.17 diff](https://github.com/sveltejs/svelte/compare/svelte@5.16.6...svelte@5.17.0). **Support:** direct, except Svelte internals, which come from a diff excerpt. **Confidence:** high / medium.
5. **Phoenix LiveView (server-rendered, the closest analogue).**
   - Templates compile into a static/dynamic split, and each dynamic expression tracks the assigns it reads (down to fields such as `@user.name`). Static parts are sent once, and unchanged dynamics are neither executed nor sent.
   - **Failure modes (the docs' own list):**
     - Variables disable tracking, and code that reads them runs on every render.
     - Passing `{assigns}` wholesale defeats tracking.
     - Changing assigns with `Map.put` is invisible.
     - Queries inside the template never re-render ("data loading should never happen inside the template").
     - Comprehensions are tracked by **index** by default, so an insertion resends every later entry. Use `:key` instead.
   - **Sources:** [assigns-eex](https://hexdocs.pm/phoenix_live_view/assigns-eex.html). **Support:** direct. **Confidence:** high.
6. **Hotwire and htmx.**
   - Turbo morph refreshes are a coarse "broadcast refresh, re-render the page, idiomorph it" signal. Server-side incrementality is left to the application.
   - **Sources:** [Turbo page refreshes](https://turbo.hotwired.dev/handbook/page_refreshes). **Support:** direct. **Confidence:** high.
   - **Inference:** htmx is the same in kind (swaps plus an optional morph extension) and offers no render memoization. I did not fetch an htmx source.

## 3. Hyperlith and Datastar practice

1. **Hyperlith now has a recursive, shared component cache.**
   - `(->Component k f)`: equality and hash use **only the key `k`** ([html.clj:25](https://github.com/andersmurphy/hyperlith/blob/a8af42afb4d1e8c3d3c72b1e88c3bc8a9a64c00a/src/hyperlith/impl/html.clj#L25)).
   - When writing, a key hit copies the cached **bytes** straight into the output buffer. A miss renders `f` and stores the written byte region ([html.clj:238–251](https://github.com/andersmurphy/hyperlith/blob/a8af42afb4d1e8c3d3c72b1e88c3bc8a9a64c00a/src/hyperlith/impl/html.clj#L238-L251)). Components nest, so the cache is recursive.
   - The cache is one Caffeine cache shared by all render lanes and connections. It is bounded by weight (default 512 MiB) and cleaned once per tick ([core.clj:176, 211, 261](https://github.com/andersmurphy/hyperlith/blob/a8af42afb4d1e8c3d3c72b1e88c3bc8a9a64c00a/src/hyperlith/core.clj#L176)).
   - **Keys are explicit and carry versions:** `(Chunk id v cells)` is keyed `[Chunk id v]`, and the write bumps `v` with `[+ v 1]` ([main.clj:366, 562](https://github.com/andersmurphy/hyperlith/blob/a8af42afb4d1e8c3d3c72b1e88c3bc8a9a64c00a/examples/billion_checkboxes_blob/src/app/main.clj#L366)). Commit `b0ba666` (2026-10-15) reads "Record components for custom cache keys mainly to allow versions".
   - **Untracked reads are forbidden, not tracked:** a database query issued while a component renders throws `"q cannot be called inside: …"` ([sqlite.clj:150](https://github.com/andersmurphy/hyperlith/blob/a8af42afb4d1e8c3d3c72b1e88c3bc8a9a64c00a/src/hyperlith/impl/sqlite.clj#L150); commit `b57f831`, "Prevent queries being called in components").
   - **Support:** direct. **Confidence:** high.
   - **Inference:** this is a *constructive trace keyed by a hand-written key*. It is sound only if the key captures every input, and the query ban enforces part of that.
2. **Older work sharing.**
   - `game_of_life` renders the board once per generation into an atom shared by every connection ([main.clj:147](https://github.com/andersmurphy/hyperlith/blob/a8af42afb4d1e8c3d3c72b1e88c3bc8a9a64c00a/examples/game_of_life/src/app/main.clj#L147)).
   - The README (commit `5519851`) describes "a simple cache that gets invalidate[d] when a `:refresh-event` is fired", with per-part invalidation as future work.
   - `billion_cells`' `chunk-cache` is a write-batch buffer, not a render cache.
   - **Support:** direct. **Confidence:** high.
3. **Anders Murphy on Discord.** All quotes are his own words.
   - Re-render fully and let compressed SSE stand in for diffing: "Gzip SSE gives you something very close to diffing without the cost, complexity or statefulness… You can cache for performance/work sharing on the server". He dropped server-side diffing because it requires per-connection view state ([2025-02-24T13:01Z](https://discord.com/channels/1296224603642925098/1333801016642244739/1343568437221396491)).
   - "work sharing/caching > fine grained events when you have a reasonable number of shared views between users" ([2025-02-06T11:58Z](https://discord.com/channels/1296224603642925098/1296225449260879973/1337029725323006016)).
   - He tried server-side signals ("signals all the way down… a common leader board component… will only ever cause a single DB query and html generation"), and asked whether this differs from "a blazing fast DB cache" ([2024-12-17T16:31Z](https://discord.com/channels/1296224603642925098/1296225449260879973/1318616682629038120)). He noted that signal libraries make cross-thread sharing hard ([2025-02-11T12:23Z](https://discord.com/channels/1296224603642925098/1333801016642244739/1338847878134759477)).
   - "I'd always do server side caching of whatever the common parts are… This was the trick used with GoL each frame was generated once and then shared between all user" ([2025-06-09T07:19Z](https://discord.com/channels/1296224603642925098/1370222812421296140/1381533172956790785)).
   - On brotli: "the compression stream is the cache is way simpler" ([2026-01-27T15:53Z](https://discord.com/channels/1296224603642925098/1296225449260879973/1465736505547821318)). Dictionaries are "not worth the squeeze" for streams past about 10–20 KB ([2026-08-01T05:15Z](https://discord.com/channels/1296224603642925098/1296225449260879973/1532980162625273966)). Use brotli level 3 with a large window; at 6 or higher "your CPU will cook" ([2026-03-10T19:44Z](https://discord.com/channels/1296224603642925098/1418614845879619795/1481014981070819339)).
   - **Support:** direct. **Confidence:** high that these are his statements. The corpus has no Anders discussion of the Sept–Oct 2026 component cache (searches for "fragment cache", "component cache" and "memoize" returned nothing relevant).
   - **Inference:** his practice splits the problem in two. Compression removes the *bandwidth* cost of a fat morph; caching removes the *generation* cost. Tuna needs only the second from this design.

## 4. Content addressing and Lisp idioms

1. **Hash-consing.** It shares structurally equal values so that equality becomes `eq?` and memo tables are cheap. It uses weak tables to avoid leaks. **Sources:** [Filliâtre & Conchon, ML'06](https://doi.org/10.1145/1159876.1159880) (abstract). **Confidence:** high for the claim, medium for the details (I read the abstract only).
2. **Unison.** Each definition is identified by a 512-bit SHA3 hash of its syntax tree, excluding names. Names are metadata. **Sources:** [big idea](https://www.unison-lang.org/docs/the-big-idea/), [hashes](https://www.unison-lang.org/docs/language-reference/hashes/). **Confidence:** high.
3. **Merkle and sparse Merkle trees.** Tuna's earlier measurement put Merkle updates at 0.5–0.9 µs against 0.015 µs for revision stamps. A full Merkle recompute was 210 µs at 50k nodes ([layout-state README](../layout-state/README.md) §1). **Fact (local measurement).**
   - **Inference:** a hash wins only when the answer must hold across processes or machines (reconnect resume, ETags, shared caches across servers), or when an external source has no revision and its payload is large.
4. **Clojure `identical?` and Elm reference equality.** With persistent data, an unchanged subtree is the same object, so a pointer check validates it in O(1).
   - **Inference:** for Tuna this applies to the layout tree (immutable, per the layout-state research) and to rope-backed text. It does not apply to a gap buffer, so it cannot be the store-independent mechanism.
5. **Emacs (editor prior art).**
   - Redisplay builds a "desired matrix" only for rows that may have changed. It uses modification counters (`MODIFF` against `unchanged_modified`) and the unchanged prefix and suffix (`beg_unchanged`, `end_unchanged`), then diffs against the current matrix.
   - jit-lock marks text dirty for asynchronous fontification with the `fontified` text property, which `jit-lock-after-change` sets to nil.
   - **Sources:** `src/xdisp.c:100–200`, `src/buffer.h:270–282`, `lisp/jit-lock.el:680–699` at `541f693`. **Support:** direct. **Confidence:** high.
   - **Inference:** Emacs is a dirty-flag and journal design tuned by hand per case.

## 5. Synthesis for Tuna

### What Tuna has today (Fact)

The renderer keeps `kept-html` per node per view, and reuses it when four inputs are unchanged:

- `node-revision`, which is stamped up the ancestor path;
- `view-state` (point and selection if the node is on the focus path, the drawn run, and the line-id offset);
- `how`, the kind's renderer, compared with `eq?`;
- the display-wide `inputs`: face-remapping and the global `keymap-generation`.

See `plugins/renderer/plugin.ss:54–65, 81–86, 184–209, 462`.

Each frame keeps only what it drew, which works as mark-and-sweep. The text contract already exposes `text-chars-revision`, `text-content-revision`, `text-decoration-revision`, and `text-changes-since` (`plugins/buffers/contract.ss`). Two open TODOs: a rebind repaints every view (`TODO.md:31`), and a key press redraws every drawn item at about 11 ms (`TODO.md:41`).

### Comparison (Inference)

| Model | Tracks deps | Key / validity | Strengths for Tuna | Failure modes for Tuna |
|---|---|---|---|---|
| Explicit dirty flags / journal (Emacs, Flutter, Tuna's node revisions) | Writer marks; the renderer lists inputs by hand | Per-node revision plus a hand-built input tuple | Cheapest writes (≈15 ns); already built | The input list drifts from what renderers actually read: stale UI if an input is missing, over-invalidation if one is too coarse (the global keymap generation) |
| Reference equality of immutable inputs (Elm, React.memo, `identical?`) | Arguments only | `eq?` per argument | O(1); no bookkeeping | Needs persistent data everywhere; mutable nodes and gap buffers fail; rebuilt-but-equal values miss |
| Content hashing / Merkle / hash-consing | None; hash the inputs | Digest | Shift-invariant; shareable across tabs, processes and reconnects | Hashing costs O(size); a hash does not answer "what changed"; collision and normalisation discipline |
| Revision tags + recorded deps (Glimmer, Salsa, Preact, Adapton) | Automatic, on read | Max revision of the deps read ≤ snapshot | Generic, so any reader is covered; nested caches compose; early cutoff with backdating; durability for global inputs | Untracked reads (globals, raw fields, async callbacks) make stale caches; bookkeeping per dep (Incremental: ≈30 ns per node; Adapton: 2.7–14× memory) |
| Hand key with versions (Hyperlith `Component`) | Programmer writes the key | `equal?` on the key | Simple; shared across connections | Same drift as dirty flags; needs a ban on reads inside components |

### Recommended model: revisioned cells with recorded reads, equality cutoff, and value keys at the leaves

All of this is a proposal (Inference); it is not a decision.

1. **One primitive, `memo`.**
   - `(memo key thunk)` returns the cached HTML fragment while every `(source . revision)` pair recorded on its last run is still current. Otherwise it re-runs the thunk inside a tracking frame.
   - The key is identity: a node id, a view name, a line id, a process id. These are Nominal Adapton's "names". The validity check is separate from the key.
   - As in Glimmer's `getValue`, a cell's recorded set is added to the enclosing frame. A parent therefore depends transitively on its children and is skipped in one check when nothing below it changed.
   - Fragments are written straight into one output port, as Hyperlith copies bytes. Avoid `string-append` at every level: Tuna's earlier measurement put root concatenation at 0.4–2.9 ms for 10k–100k nodes.
2. **Sources.**
   - Every piece of mutable state a renderer may read is a source with a revision, read through an accessor that records the read: node fields and children, text characters, decoration spans, the cursor set, keymaps, faces, client-view, settings.
   - Tuna's per-node revision becomes the node's source revision. The ancestor stamp is kept as a precomputed combined tag.
   - The revision space can be global and monotonic, like Glimmer's `$REVISION`. A per-source counter is not needed.
3. **Early cutoff.**
   - A derived cell may declare `equal?`-cutoff. When it re-runs and produces an equal value, its revision stays the same (Salsa backdating, Preact versions).
   - Use this where cheap values intercept noisy inputs: "this line's text plus spans plus cursor columns", "the git status as parsed", "the clickable set for this node's keymap".
4. **Leaves use value keys.**
   - For items inside a text node, the validity of a line's HTML is the `equal?` of its small input value: the line string, the decoration spans clipped to the line, the cursor columns in the line, and the line id.
   - It is not the text's revision, which changes on every edit, and not the line's position, which shifts on insert. This is LiveView's index-tracking failure.
   - This needs from any text store only "the text and spans of line *i*". Ropes and gap buffers both provide it, so it is store-independent, and it costs about one substring and one compare per visible line.
5. **External and async state.**
   - A plugin owns a source and writes it only on the editor thread. A poller or file watcher job computes the new value and calls `(source-set! s v)`. That call bumps the revision only if `(not (equal? old v))`, or, for large payloads, if a digest differs.
   - Each git-status section or process row is then a `memo` keyed by its stable id (path, pid) with value cutoff. Only changed rows are rebuilt, and DOM ids stay stable.
   - Asynchronous highlighting writes the decoration source. Lines whose spans did not change keep their HTML.
   - A clock is a volatile source and is always invalid. Keep it to small cells.
6. **Durability for global inputs.**
   - Keymaps, theme and face remapping should be fine-grained sources read where they are used, for example a node's own keymap revision. This fixes `TODO.md:31` without any special case.
   - If the check cost of rarely-changing globals ever shows up, add Salsa-style durability tiers.
7. **Tabs and work sharing.**
   - A cell that did not read a per-client source (`client-view`, per-tab state) can be shared by every tab. One that did must include the client in its key.
   - **Inference:** recorded reads make this sharing automatic, which a hand-written key cannot. That is Anders's "work sharing" obtained for free.
8. **Guardrails, taken from the failure modes above.**
   - In test builds, fail on any read of a source outside an accessor during a memo run. This is Hyperlith's query ban, generalized.
   - Fail on a source write during rendering (Glimmer's consumed-tag assertion).
   - Keep the per-frame mark-and-sweep, so cache lifetime equals "drawn last frame" and no LRU is needed. Hyperlith's weighted LRU suits caches shared across many users.
   - Track at the granularity of node, line and row, never character. That keeps the per-dependency overhead below the HTML cost it saves.

**Why not the alternatives as the single mechanism (Inference):**

- Reference equality needs persistent data that Tuna's mutable nodes and gap buffers lack.
- Hashing pays O(size) on every check, cannot say what changed, and its cross-process benefit is not needed when one Tuna process renders for its own tabs.
- Hand-listed keys are today's model, and its two TODOs are exactly that model's failure modes.

Recorded reads keep the immediate-mode `UI = f(state)` code unchanged: renderers stay ordinary recursive functions. Only the accessors know about revisions.

## Contradictions

- The layout-state research recommended per-node-id Datastar patches. The owner rejected that on 2026-10-13 in favour of a whole-screen fat morph. Anders also prefers full re-render plus compression. No conflict remains with the recommendation, which affects generation only.
- Anders asked whether server-side signals are "really any different than having a blazing fast DB cache" (2024-12-17). In 2026 Hyperlith moved to keyed components rather than signals. His practice favours hand keys; this brief favours recorded reads. The difference is Tuna's many readers of mutable state, which is an inference.

## Missing evidence

- Nothing has been measured in Gerbil for per-read tracking overhead, or for `equal?` keys on about 100 visible lines. A spike is needed before committing.
- Gerbil's weak-table API was not checked here (use the gerbil-reference skill). Per-frame sweep may make weak tables unnecessary anyway.
- Skip and Nominal Adapton were read only from excerpts and the abstract. The Svelte 5 internals come from a diff excerpt.
- There is no primary statement from Anders on the Sept–Oct 2026 component cache. Its design is inferred from the code and commit messages.

## Sources

- **Kept:** Glimmer validators.ts and tracking.ts (permalinks above): the minimal tag and cache algorithm.
- **Kept:** Salsa algorithm page and rust-analyzer "Durable incrementality": backdating and durability.
- **Kept:** Adapton (PLDI'14) and Nominal Adapton: demand-driven repair, and names as keys.
- **Kept:** Jane Street Incremental and Bonsai: cost per node and explicit cutoff.
- **Kept:** Build Systems à la Carte: the taxonomy and the failure modes.
- **Kept:** React memo, Elm Lazy.elm, Inside Flutter, Solid, Preact Signal Boosting, Svelte runes: the equality and version variants.
- **Kept:** LiveView assigns-eex: the server-rendered analogue and its documented pitfalls.
- **Kept:** Hyperlith source at `a8af42a`, and Anders on Discord (links above): Datastar practice.
- **Kept:** Emacs xdisp.c, buffer.h and jit-lock.el at `541f693`: the editor baseline.
- **Kept:** Unison docs and Filliâtre & Conchon: content addressing.
- **Kept:** Tuna `plugins/renderer/plugin.ss`, `TODO.md`, and `agents/research/layout-state/README.md`: the current state and earlier measurements.
- **Deprioritized:** the Skip docs (rendered by JavaScript; excerpts only); justjake/signals-design-space (a secondary survey, used only to locate Svelte internals); Hotwire and htmx (they have no server-side memoization to learn from).
- **Rejected:** the pzuraq autotracking blog (404).

## Next steps

1. Spike in a worktree, owned by the renderer plugin: a `memo`/source library of about 100 lines in `tuna/lib/` or in the renderer. Port line rendering to value keys, and measure the TODO's 11 ms key press and the bytes per frame.
2. Decide where `source` lives. It is a library, not the kernel (ADR 12), because buffers, layout and external-state plugins all need it.
3. Prototype a polled `git status` source with `equal?` cutoff to confirm the external-state path end to end.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Summary-first brief that surveys all four requested areas with primary citations (permalinks, Discord links, local code lines), compares four models in a table, recommends one model with rationale and an external-state path, and lists residual risks under Missing evidence."
    }
  ],
  "changedFiles": [],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "uv run corpus.py search ... (datastar-discord-export)",
      "result": "passed",
      "summary": "Found Anders statements on work sharing, caching and brotli; none on the 2026 component cache"
    },
    {
      "command": "git show origin/master:... (hyperlith)",
      "result": "passed",
      "summary": "Read the Component fragment cache, the query ban and versioned keys at a8af42a"
    }
  ],
  "validationOutput": [
    "Key claims were checked against fetched primary sources: Glimmer source, Salsa docs, the BSalC PDF, the Adapton PDF, LiveView docs, React, Elm, Flutter, Preact and Solid docs, and Emacs source"
  ],
  "residualRisks": [
    "Gerbil overhead of per-read tracking and equal? line keys is unmeasured",
    "Skip, Nominal Adapton and Svelte internals are based on excerpts or abstracts only",
    "Hyperlith's component-cache design is inferred from code and commits, not from a statement by its author",
    "The local hyperlith master (34dbe2e) is older than origin/master (a8af42a); the citations use origin/master"
  ],
  "noStagedFiles": true,
  "diffSummary": "No repository changes; the artifact was written only to the authoritative output path",
  "reviewFindings": [
    "no blockers"
  ],
  "manualNotes": "The recommendation is labelled as inference throughout. It generalizes Tuna's existing kept-html (revision + view-state + how + inputs) from hand-listed inputs to recorded reads with equality cutoff, and uses value keys for lines and rows."
}
```
