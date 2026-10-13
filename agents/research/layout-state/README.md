# Layout and buffer tree state: representation, incremental rendering, persistence

> **Owner decision, 2026-10-13:** the recommendation below to send Datastar patches for individual changed node ids is rejected. Rendering stays immediate mode (UI = function(state)): every redisplay streams the whole visible UI as one fat morph. Per-node revisions remain useful as server-side memoization keys so unchanged parts' HTML is not recomputed. See agents/STATUS.md owner decisions.

Research, 2026-10-13. Read-only on code; benchmark and results are in [`bench/`](bench/). Labels: **Fact** (checked in a source or measured), **Inference** (my reasoning), **Unverified** (not checked). Evidence, not decisions.

## Answer

**Do not make one big stored structure. Make one big *presented* tree and keep the owners separate.**

- **Layout tree** (about 50 nodes): an *immutable* plain-data tree held in one mutable cell by the layout plugin. A change builds a new tree by path copying (about 0.1 µs at 52 nodes); the old value is a free snapshot (Emacs window configurations, layout undo, handover to another window manager). It saves as one plain-data session slot (322 bytes, about 23 µs to write). Cost is irrelevant at this size, so choose for snapshots and saving.
- **Buffer node trees** (10k–100k nodes for a rich buffer; one text node for most buffers): *mutable* nodes with stable ids, a parent link, and a per-node revision. A change mutates the node, stamps the revisions up its path, and appends to the buffer's change journal (15–30 ns for the whole thing at any size). This is already ADR 4's model; text inside text nodes stays on the persistent rope. Per-view state (cursor, scroll, folding) lives in the view, keyed by node id, never in the shared tree.
- **Rendering stays incremental** because each rendered element carries its node id (`id="n42"`) and a plugin reports "nodes changed since revision R". The renderer sends a Datastar element patch only for the topmost changed subtrees. Datastar morphs by element id, so a patch costs what the changed subtree costs. A whole-screen fat morph remains the fallback.
- **Hashes are not needed.** Revisions answer "what changed since I last looked" in O(path). Merkle hashes answer "is this equal to something I saw" and cost more (0.5–0.9 µs per update vs 0.015). Skip them until something needs content equality (remote sync, deduplicated saves).
- **Kernel vs library vs plugin:** not in the kernel. No shared tree library yet either, because the two trees want *different* representations. Share a small read-only *presentation protocol* (id, kind, revision, children) at the renderer-service layer, which gives the "one tree all the way down" the owner wants without one owner or one representation. Extract a `tuna/lib/` helper only when a second plugin proves identical needs.

The measured bottleneck is **serialization, not state update**: writing HTML for a 50k-node buffer costs about 32 ms by raw string writes and an estimated 250 ms through `write-sxml`; viewport-sized output (about 500 nodes) costs about 2.5 ms. Any state representation is fast enough; what matters is never rendering everything.

## 1. Performance and state representation

**Do we rewrite the whole structure on every change?** Only if it is stored as one immutable value with no structural sharing. Candidates, measured on this machine (section 5):

| Representation | One-leaf update, 52-node layout | 50k-node buffer | Change info for the renderer | Snapshot | Fit |
|---|---|---|---|---|---|
| Persistent path copy, vector children | 0.16 µs | 0.11 µs (fanout ≤ 100) · 0.14 µs (fanout ≤ 200) · **130 µs** if one parent has 50k children | Pointer equality (`eq?`) of unchanged subtrees | Free | Layout tree. Buffers only with bounded fanout (a B-tree or rope, as the text store already is) |
| Persistent path copy, list children (today's `node` in `buffers.ss`) | 0.06 µs | 0.24 µs · 0.7 µs at fanout 200 · 86 µs at 50k | Same | Free | Fine for small trees |
| Path copy plus cached Merkle hash | 0.11 µs | 0.56 µs · 0.83 µs at 100k | Hash equality, no history needed | Free | Only if content equality is a goal |
| **Mutable node, ancestor revisions, journal** | **0.012 µs** | **0.014 µs** at any fanout | "Dirty since R" by revision; journal lists exact changes | Needs a copy or a journal | Buffer nodes (matches ADR 4) |
| Arena (id → record table, ancestor revisions) | 0.15 µs | 0.15–0.24 µs | Same as mutable | No | Not worth the table lookups unless ids must be dense or serializable |
| Full Merkle recompute, no cache | 0.2 µs | 210 µs (50k) · 410 µs (100k) | — | — | Full rehash is cheap in absolute terms, so even uncached hashing would not be a bottleneck |

- **Fact (measured):** path copying costs O(depth × fanout), so it is cheap for trees with small, bounded fanout and bad for a node with a huge flat child list. Mutation costs O(depth) for revisions and nothing for fanout.
- **Inference:** a magit-like buffer is wide and shallow (hundreds of sections, tens of lines each). Persistent children would need chunked child lists. That is the rope/SumTree machinery ADR 6 already treats as costly in Gerbil/Racket (prior numbers in section 2). Mutable nodes plus revisions avoid it.
- **Inference:** keep ADR 4's rule, not an immutable root. A persistent layout value inside a plugin-owned mutable cell does not contradict ADR 4, because state is still plugin-owned and baton-confined; only the cell's content is a value.
- **Per-node revisions vs hashes:** revisions are monotonically increasing integers stamped on the changed node and its ancestors (O(depth) writes). A renderer remembers "last sent revision" per client and visits only subtrees with a newer revision (measured 1–2.7 µs to find the dirty path in a 50k–100k node tree, against 135–270 µs for a full traversal). Hashes need no history but cost O(fanout × depth) per update and cannot say *when* a change happened. The journal (ADR 4) already gives exact change records; revisions tell the renderer where to look.
- **Incremental rendering contract (Inference):** each node gives `(node-id n)`, `(node-revision n)`, `(node-children n)`. The renderer emits `id="n<id>"` on every node's element. The plugin that owns a tree exposes `(nodes-changed-since rev)`, or just the root's revision when nothing changed. The renderer finds the topmost changed ids and sends one Datastar patch per subtree. Datastar's default patch morphs "top-level elements by ID" ([vendored docs](../../reference/datastar/docs.md), "In Morph We Trust"). Fall back to a full screen morph when the journal no longer covers a client's last revision.
- **Memoized render caveat (Fact, measured):** caching rendered strings per persistent node, then concatenating, still copies the whole output at the root each time: 0.4 ms at 10k nodes, 1.7–2.9 ms at 50k–100k, against 0.001 ms to find the dirty path. Patch the subtree, not the concatenated screen.
- **Large buffers need viewport slicing regardless (Inference):** ADR 7 gives layout to the browser, so the server cannot know what is visible. The client must report a visible node range, or the server sends lazily expanded or folded sections. How a 100k-node DOM behaves in the browser is **Unverified** and not measured here. This is the open question that matters most for rich buffers (see section 6).

**Persistence (Fact + Inference):**

- Layout: one session slot ([ADR 5](../../adr/0005-persistence.md)); the existing windows slot already saves plain data (`window-description->data` in `tuna/services/windows.ss`). A layout tree writes as nested plain data: 322 bytes, 23 µs to write, 3.5 µs to read (52 nodes). Restoring tolerates missing buffers, as the current slot does.
- Buffers: persist only what Emacs's desktop saves (name, file, point, mode); regenerate rich buffers (magit, dired) from their mode. If a rich tree must persist, plain data is 90 KB / 6 ms at 10k nodes, 500 KB / 34–42 ms at 50k, and 1 MB / 62–67 ms at 100k nodes. That suits an idle autosave, not a per-keystroke save. Text content belongs to the autosave plugin and the rope, not to the node tree.
- Layout persists as a value; buffers persist per buffer. Persistence is never one atomic snapshot (ADR 5 already says so).

## 2. Prior work found locally (not authority)

- **No sparse Merkle tree research exists anywhere I searched.** I searched `tuna/`, `tuna-old/`, `tuna-old-2026-10/` (including `git log --all -S"merkle"` across all refs and `stash@{0}`) and the wider `workbench-gerbil` tree for Merkle, hash tree, HAMT, content-addressing, hash-consing. The only hits for "sparse" are *sparse keymaps* and the old buffer spec's "sparse tokens / source maps" for HTML. **Fact.** The memory may come from a conversation or another repository. **Unverified.**
- **Persistent collections in Gerbil:** an earlier report ([`gerbil-immutable-state-feasibility.md`](../editor-corpus/prior-art/workbench-gerbil/research/gerbil-immutable-state-feasibility.md), Gerbil v0.19-dev-31) found no installed persistent hash map or vector; SRFI 146 (HAMT) exists only as retired source. It also noted that struct copy is shallow and immutability is by convention. **Version-sensitive; re-verify before relying on it.**
- **Immutable-root spike** ([`tuna-immutable-state-spike-results.md`](../editor-corpus/prior-art/workbench-gerbil/research/tuna-immutable-state-spike-results.md)): a new root per command was feasible, but ADR 4 chose mutable owned objects.
- **Application-state research** ([`tuna-gerbil-2026-10/tuna-app-state/findings.md`](../tuna-gerbil-2026-10/tuna-app-state/findings.md)): render read-side data and recovery checkpoints are different projections; do not clone all text per key; checkpoint is periodic, on the owner. The old Racket persistence saved only buffer id/file pairs and views at point 0 (`prior/racket-persistence.rkt`), a limitation noted there.
- **Text store numbers (ADR 6; Racket, not Gerbil):** a generic SumTree was about 680× slower than a gap buffer on local edits (1 MiB trace: 2015 ms vs 2.96 ms; gap-buffer snapshot copy 5.2 ms; [`sum-tree-docs/performance.md`](../editor-corpus/prior-art/tuna-stashed-sum-tree/sum-tree-docs/performance.md)); Weevil's rope: 0.29 ms flat insert at 1 MB and 10 MB against 72/735 ms for strings, 60× less snapshot memory ([`buffer-rope-benchmark-results.md`](../editor-corpus/prior-art/weevil/plans/archive/buffer-rope-benchmark-results.md)). **Lesson:** persistent trees pay off for large flat sequences (text) and snapshots, and cost constant factors elsewhere; consistent with the measurements below.
- **Layout prior art:** the Racket layout was an immutable `struct` tree with validation and declarative scroll anchors (`../window-management/code/racket-tuna-layout.rkt`, 600 lines); Weevil computed geometry on the server; ADR 7 now gives geometry to the browser.
- **Profiler tree UI research** (`../editor-corpus/prior-art/workbench-gerbil/research/tuna-profiler-tree-ui-research.md`): outer morphs overwrote `<details open>` unless `data-preserve-attr="open"` was set. Relevant to per-node fold state surviving morphs; the lesson is that view state a patch can overwrite must be either server-owned or preserved.

## 3. Prior art (primary sources; each item: storage / change / render / save)

- **i3 and sway.** *Storage:* mutable tree of containers (`nodes`, `floating_nodes`, `focus` list in focus order, layout, `percent`); [GET_TREE reply](https://i3wm.org/docs/ipc.html) serializes the whole tree to clients (ids are C pointer values). *Change:* in-place mutation by commands. *Render:* the window manager recomputes geometry; clients get events and may re-fetch the tree. *Save:* layouts saved to JSON per workspace by `append_layout` (i3 docs; not re-read here). sway mirrors the i3 IPC (sway-ipc man page; **Unverified**, not fetched). *Relevance:* focus order is a list per container, so per-container focus memory belongs in the tree (answers ADR 11's open question in the i3 way).
- **niri.** *Storage:* mutable Rust structs; `ScrollingSpace` holds `columns: Vec<Column>`, `active_column_idx`; a column holds tiles and `active_tile_idx` (`src/layout/scrolling.rs:35–43,146–158` at niri `a30ca79`, local checkout). Workspaces are separate structs. *Change:* in place; view offset animates toward the active column. *IPC:* `niri-ipc` 26.4.0 (`niri-ipc/src/lib.rs`). Event-stream diff semantics: **Unverified.** Focus memory is per container (`active_*_idx`), as in i3.
- **Emacs windows.** *Storage:* mutable C `struct window` tree (parent/prev/child pointers). *Snapshot:* `current-window-configuration` copies it into a vector of `struct saved_window` (`src/window.c:7595–7640` at Emacs `541f693`), and `set-window-configuration` rebuilds from it. `window-state-get` returns the tree as Lisp data that "can be stored on disk and read back in a new session" (`lisp/window.el:6487–6503`, same commit). *Lesson:* snapshots are copies of a small tree, and a writable data form exists for sessions. Same shape as the recommendation for the layout tree.
- **Zed.** *Panes:* pane groups are a tree (`SerializedPaneGroup::Group{axis, children, flexes}` / `Pane`) persisted to SQLite tables `pane_groups`, `panes`, `items`, with the whole workspace rewritten on save (`DELETE FROM pane_groups … ; save_pane_group` recursion; [persistence.rs](https://github.com/zed-industries/zed/blob/main/crates/workspace/src/persistence.rs), moving branch, fetched 2026-10-13, commit not pinned). *Text:* `SumTree<T>` is an `Arc` copy-on-write B+ tree whose nodes carry summaries; snapshots bump a refcount ([Zed blog](https://zed.dev/blog/zed-decoded-rope-sumtree), pinned code links to `6721c91`). *Lesson:* a persistent B+ tree is a text/sequence tool; layout is a small tree rewritten whole on save. The owner rejected SQLite for Tuna state (ADR 5).
- **Xi / Lapce.** Not checked here; Xi's rope-as-monoid design is cited by Zed's post. **Unverified; not needed for the recommendation.**
- **Browser DOM and React.** *Storage:* mutable DOM; React rebuilds a virtual tree and diffs with an O(n) heuristic (different types differ; `key` hints stable children), because general tree edit distance is O(n³) ([React reconciliation](https://legacy.reactjs.org/docs/reconciliation.html)). *Lesson:* stable ids are the key to cheap diffs; reordering without keys is expensive.
- **Flutter.** *Storage:* immutable widgets, mutable element and render-object trees. A dirty list lets the build phase jump straight to dirty elements; an unchanged immutable widget is recognized by identity; reconciliation is a linear per-child-list algorithm, not a tree diff ([Inside Flutter](https://docs.flutter.dev/resources/inside-flutter)). *Lesson:* the same pairing as the recommendation: immutable descriptions (layout value) over mutable retained trees (buffer nodes) with dirty marking.
- **Jetpack Compose.** *Change:* state reads re-run only the composable functions that read changed state and skip the rest ([Thinking in Compose](https://developer.android.com/develop/ui/compose/mental-model)). Its slot table (gap buffer) is not covered by that page: **Unverified.**
- **Datastar and idiomorph.** Datastar morphs top-level elements into the DOM "based on the element IDs" and supports `data-ignore-morph` and attribute preservation (vendored `agents/reference/datastar/docs.md`). Idiomorph matches elements by *id sets* (all ids inside an element) so id-less wrappers still match, preserving focus and state; it is roughly equal to 10% slower than morphdom for large morphs, built for matching quality, not speed ([idiomorph README](https://github.com/bigskysoftware/idiomorph/blob/main/README.md), v0.8.0 in the install snippet). *Lesson:* put stable ids on every node element; the id *is* the diff protocol.

## 4. Kernel, shared library, or plugin?

Assessed against ADR 12 (and AGENTS.md "Keep the kernel small"):

1. **Kernel: no.** The kernel "must never know… text, characters, positions, ranges, changes to text, buffers, views, windows, frames, screens." A node tree whose only content is structure, modification, and persistence is still a data structure that exactly two features use (windows, buffers), so its API would be shaped around them. It would also be the one data structure the owner could not replace without upgrading Tuna (fixed tier), contradicting "data structures user-replaceable." Persistence is explicitly the session plugin's job. Every kernel addition needs an ADR amendment saying why no plugin or library could own it; here one clearly could.
2. **Shared library (`tuna/lib/tree.ss`): not yet.** Libraries are allowed (conveniences on the public kernel API), but AGENTS.md asks for a second concrete user before a framework. The measured evidence says the two users want *different* representations (layout: immutable value for snapshots; buffer nodes: mutable with revisions because fanout is wide). A library general enough for both would be a compromise that serves neither, and layout containers have kinds (`fit`/`scroll`/`tabbed`) with measures on edges while buffer nodes have attributes and text. That is the single-consumer-contract failure ADR 12 warns about.
3. **Each plugin's own structure: yes.** Buffers plugin owns node classes (add `revision` and `parent` there; today `node` in `buffers.ss` has only `id kind attributes children`). Layout plugin owns an immutable tree type. Replacement works through the existing contracts: `WindowManager.describe-windows` / `adopt-windows!`, and a buffers contract for nodes.
4. **What *is* shared: a presentation protocol** in `tuna/services/` (a contract, not a library): a read-only view of any tree as `id`, `kind`, `revision`, `children`, plus `changed-since`. The renderer service consumes it; window-manager and buffer plugins implement it. Then the whole screen is one tree as presented and navigated: the layout's leaf renders the buffer's node tree in place (the current `render-window` already calls `render-node (buffer-root b)`), and a frame can show any focused subtree. Two owners in data, one tree in presentation; this is the architect's proposal and the evidence supports it.
5. **When to extract a library:** when two plugins implement the same *algorithm*, not the same *shape*. Likely early candidates are small and pure: node-path addressing (list of ids), "topmost dirty ids" given revisions, and a plain-data tree walker for saving. Put them in `tuna/lib/` then.

## 5. Gerbil measurements

Machine: 16 cores; Gerbil v0.19-dev-63-g1cfb032c (Gambit v4.9.8-19-gea114fc3), `gxc -exe -O`, default safety (no `(declare (not safe))`). Code: [`bench/bench.ss`](bench/bench.ss) (build in `/tmp/lbench`: `gxc -exe -O -o bench bench.ss`). Raw output: `bench/run2.txt`, `bench/run3.txt` (run 1, with other load on the machine, was 1.5–3× slower and is not used). Runs 2 and 3 agree within about 10%; numbers below are run 3 unless noted. Nodes are `defstruct`s with a fixnum payload; fanouts `(3 4 3)` = 52 nodes; `(20 10 50)` = 10,221; `(100 10 50)` = 51,101; `(200 10 50)` = 102,201 (leaf-heavy, depth 3 plus leaves, update at the middle leaf); flat = one root with 50,000 children. Update measurements are µs per operation, averaged over 500–20,000 repetitions.

| Operation (µs) | layout 52 | buffer 10k | buffer 50k | buffer 100k | flat 50k |
|---|---|---|---|---|---|
| Persistent path copy, vector kids | 0.16 | 0.08 | 0.11 | 0.14 | 143 |
| Persistent path copy, list kids | 0.06 | 0.13 | 0.24 | 0.68 | 86 |
| Persistent + Merkle hash on path | 0.12 | 0.26 | 0.56 | 0.83 | 240 |
| Mutable set + ancestor revisions + journal | 0.012 | 0.018 | 0.014 | 0.014 | 0.017 |
| Mutable + invalidate hash on path + lazy rehash | 0.056* | 0.49* | 0.9* | 1.3* | 292* |
| Arena (id table) set + ancestor revisions | 0.15 | 0.16 | 0.15 | 0.15 | 0.08 |
| Full Merkle recompute, no cache | 0.21 | 40 | 210 | 411 | 179 |
| Full traversal (count nodes) | 0.15 | 26 | 135 | 271 | 122 |
| Full render to HTML in a string port | 19 | 4,900 | 32,000 | 53,500 | 22,800 |
| Memoized render after one path-copy update | 9.8 | 392 | 1,680 | 2,820 | 8,760 |
| Dirty-path-only render (mutable + revisions) | 0.98 | 0.69 | 0.98 | 1.5 | 150 |
| Persist: `write` plain data to string | 22.6 | 5,900 | 33,500–41,900 | 62,200 | 41,000–43,000 |
| Persist: `read` plain data back | 3.5 | 760 | 4,100 | 8,100 | 4,000 |
| Persisted size (bytes) | 322 | 90,661 | 497,701 | 1,008,703 | 488,901 |

\* first run (loaded machine); run 3 values were similar in ratio. `write-sxml` of a 511-node SXML tree (build + write): about 2,500 µs, about 5 µs per node (viewport case).

Caveats (Fact about the benchmark): single machine, one build mode, synthetic payloads; the Merkle hash is a cheap fixnum mix, not cryptographic (SHA-256 would be far slower, unmeasured); memoized-render cache is never evicted, so its row includes cache growth; allocation and GC retention of path-copied trees was not isolated; no concurrent snapshot reader was modeled; the flat shape is the worst case for path copying and the best case for mutation. Browser DOM cost was not measured.

## 6. Open questions for the owner

1. **Large rich buffers: who decides what is rendered?** The server cannot know the viewport (ADR 7). *Recommendation:* the client reports a visible range of node ids (a small event), and the server renders that range plus a margin; the same mechanism serves scrolling containers. Decide in the layout-facts research before windows are built.
2. **Where does per-container focus memory live?** ADR 11 says frame view state; i3 and niri keep it in the tree (focus list, `active_*_idx`). *Recommendation:* keep it in the layout value (`active-child` per container), which makes "go back to the same window" survive layout snapshots and is what Emacs window configurations store; ADR 11 can be amended.
3. **Is a node tree the same thing as a layout tree?** *Recommendation:* no, keep two owners and one presentation protocol (section 4). This preserves replaceability and lets one buffer be shown by several views.
4. **Do we want Merkle hashes?** *Recommendation:* no; revisions plus the journal cover rendering and rebasing. Revisit only for remote sync or deduplicated saving.
5. **Persist rich buffer trees?** *Recommendation:* no; persist name, mode, and view state, and let the mode rebuild the buffer, as Emacs's desktop does.
6. **Should the layout plugin keep undo history of layouts?** The immutable value makes it nearly free (keep the last N values). *Recommendation:* offer it as a window-manager feature later, not in the contract.

## Where this is shallow

- Xi, Lapce, sway internals, niri event diffs, Compose's slot table: not read.
- Browser-side cost of large DOMs and of many small patches: not measured (needs a browser test through the real Datastar stream).
- No benchmark of path-copy GC retention, nor of persistent B-tree children in Gerbil.
- Zed's persistence file is a moving branch; the commit was not pinned.
- The claim that no Merkle research exists is limited to the repositories searched; `.pi-subagents/artifacts` and old session transcripts mention "merkle" only in an unrelated naming-conventions report.

## Sources

Local (all read in this run): `docs/overview.md`, `docs/ideas/window-management.md`, ADRs 4, 5, 6, 7, 11, 12, `agents/STATUS.md`, `tuna/services/buffers.ss` (node, buffer, view, text revisions), `tuna/services/windows.ss`, `tuna/plugins/single-window.ss`, `tuna/plugins/html-renderer.ss`, `tuna/plugins/session.ss` (skimmed), `agents/research/window-management/README.md`, `agents/research/owner-notes/layout.org`, the prior-research files named in section 2, `/home/jay/Code/emacs` at `541f693ca2e8de166cfe52c39bbfc497142215e9`, `/home/jay/Code/niri` at `a30ca7983b2f1fc3ddeb209b3fe18fa78e0dbd25`.

Web (fetched 2026-10-13): [i3 IPC](https://i3wm.org/docs/ipc.html); [Zed workspace persistence](https://github.com/zed-industries/zed/blob/main/crates/workspace/src/persistence.rs); [Zed Rope & SumTree](https://zed.dev/blog/zed-decoded-rope-sumtree); [React reconciliation](https://legacy.reactjs.org/docs/reconciliation.html); [Inside Flutter](https://docs.flutter.dev/resources/inside-flutter); [Thinking in Compose](https://developer.android.com/develop/ui/compose/mental-model); [idiomorph README](https://github.com/bigskysoftware/idiomorph/blob/main/README.md); vendored Datastar docs in `agents/reference/datastar/docs.md`.

Deprioritized: React's newer docs (the legacy page states the algorithm directly); search-engine summaries (none used for claims).
