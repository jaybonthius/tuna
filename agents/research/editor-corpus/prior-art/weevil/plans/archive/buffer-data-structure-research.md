# Buffer Data Structure Research

Status: research brief (web + codebase)
Date: 2026-06-16

## Question

Weevil's buffer is currently stored as a single immutable Racket string plus
two parallel line-start index vectors. Every edit rebuilds the whole string and
re-scans it to rebuild the indexes, so **every keystroke is O(n) in buffer
size**. We need to decide what to replace it with. Candidates raised: gap
buffer, rope, piece table, "maybe others". This brief researches the options
and recommends one that fits Weevil's specific architecture.

The relevant Weevil-specific twist (called out by the requester): the browser
client sends **individual keystrokes**, which become single-character commands
on the server. We almost never push bulk text to the server, except cases like
paste. So the dominant write is a **localized single-character insert/delete at
point**, with occasional bulk inserts.

We follow Emacs as a reference but are explicitly allowed to diverge with good
reason. (And on this topic we should: Emacs's gap buffer is a poor fit for
Weevil's immutable, snapshot-driven architecture — see below.)

## Short answer

**Recommended target: an augmented, persistent rope** — a balanced tree (B-tree
/ B+-tree) of small UTF-8 string chunks, where every node caches *summary
metadata* about its subtree (byte length, char length, UTF-16 length, newline
count, last-line lengths). This is the "SumTree" design Zed uses and the
monoid-summary rope xi-editor uses.

Why this and not the others, for Weevil specifically:

1. **Weevil's buffer model is immutable/functional** (`buffer-model` is an
   immutable struct; edits return a *new* model via `struct-copy`). Persistent
   ropes are immutable with structural sharing, so a "new version" is a few new
   nodes plus shared subtrees — not a whole-buffer copy. Gap buffers are
   mutable-in-place and fight this model.

2. **Cheap snapshots are load-bearing in Weevil's architecture**, not a nice-to-
   have: server-owned undo at command granularity, per-render SSE revisions, and
   (planned) background tree-sitter re-parsing all want a frozen view of the
   buffer at a point in time. A persistent rope snapshot is O(1) (share the
   root). A gap-buffer snapshot is O(n) (copy everything). Zed built its entire
   editor on exactly this property — every edit ships a buffer snapshot to a
   background thread for tree-sitter, cheaply, because the rope is persistent.

3. **The expensive recurring work per keystroke in Weevil is not the edit — it
   is the coordinate conversions and line indexing for rendering.** Right now
   that is the O(n) full re-scan in `buffer-model-from-string` plus the linear
   scans in `position.rkt`. An augmented rope folds byte↔char↔line↔UTF-16
   conversions, line count, and visible-range slicing into a single structure,
   all O(log n). This is the single biggest win and the strongest reason to
   prefer a *summary* rope over a plain piece table.

4. The per-keystroke / "client sends keystrokes, not text" detail does **not**
   push us toward a gap buffer. A single-char insert is O(log n) on a rope
   (instant for any realistic file), consecutive inserts coalesce into one leaf
   (so typing a word is not one node per character), and paste is one
   O(log n + m) splice. The thing that actually costs us today — rebuilding
   indexes and converting coordinates for the render — is what the rope fixes.

**Strong runner-up: a piece tree (VS Code style).** Append-only and therefore
immutability- and undo-friendly, excellent load time and memory (original file
bytes stay read-only and can be memory-mapped), and arguably easier to get
correct than a full summary rope. Its weaknesses relative to the augmented rope:
it needs extra machinery for char/UTF-16 column conversion (the red-black tree
only indexes offset + line breaks by default), and it fragments over a long
editing session (many small pieces), requiring periodic coalescing.

**Not recommended as the target:** the current whole-string approach (O(n) per
keystroke) and a gap buffer (conflicts with the immutable/snapshot
architecture; snapshots cost O(n)). Array-of-lines is a non-target too.

**Racket reality check:** do not assume `treelist`/RRB vectors make this free.
The `racket-langserver` project tried a **treelist-based** rope textbuffer,
found it *"still too slow for big files,"* and switched to a hand-rolled
**immutable rope** instead. So budget for a custom chunked tree and benchmark in
Racket CS — and honor the ADR's benchmark gate, which currently has **no
benchmark harness in `tests/` at all**.

---

## What Weevil has today

Relevant files:

- `weevil/private/core/buffer-model.rkt`
  - `(struct buffer-model (text line-starts line-start-bytes))` — an immutable
    Racket string plus two immutable vectors (char index and byte offset of each
    line start).
  - `buffer-model-from-string` does a single O(n) pass to build both index
    vectors. **It is called on every insert and every delete**, so each edit is
    O(n): `string-append` + `substring` to make the new string, then a full
    re-scan to rebuild indexes.
  - `buffer-model-insert` / `-delete` / `-backspace` are the editing seam.
  - Index-assisted lookups (`byte->char`, `byte->line/utf16-column`) binary-
    search the line vectors then scan within the line — good, but they sit on
    top of a structure that is rebuilt wholesale every edit.
- `weevil/private/core/position.rkt`
  - Pure string helpers: UTF-8/UTF-16 widths, codepoint-boundary checks, word /
    line / column scanners. Several are O(n) linear scans over the whole string
    (e.g. `byte-offset->char-index`, `byte-offset->line/utf16-column`,
    `line/utf16-column->byte-offset`).
- `weevil/private/core/buffer-text-state.rkt`
  - Thin wrapper holding a `model`; this is the seam the ADR intends to swap
    behind.
- `weevil/private/core/marker-state.rkt`
  - Markers are external byte offsets with Emacs-style insertion bias, adjusted
    by `after-insert` / `after-delete` deltas. Independent of the storage
    structure — keep as-is.
- `weevil/private/core/buffer-state.rkt`
  - Buffer metadata; text payload is one level deeper so indirect buffers can
    share text. Reinforces that storage is private and swappable.

What the ADR already commits to (so this brief is choosing *within* that
decision, not relitigating it):

- `ADR.md` → "Buffer Storage" and "ADR: Buffer Representation and Benchmark
  Gate": *do not ship whole-buffer strings for v1; use a benchmarked piece-
  table/rope-like structure*; a plausible design is "immutable original bytes +
  append-only add buffer + balanced sequence of pieces (treelists or custom
  tree) + cached line-start indexes + marker/overlay indexes with insertion
  bias." That description is essentially a piece tree *or* a summary rope.
- `ADR.md` → "ADR: Canonical Position Unit": internal positions are UTF-8 byte
  offsets; public API is 1-based chars; LSP is UTF-16 line/col; browser is
  UTF-16 column within a line. So the structure must make **byte ↔ char ↔ line ↔
  UTF-16** conversions cheap. (This is exactly what a summary rope is best at.)
- `ADR.md` → "ADR: Undo/Redo": server-owned, command-granularity, with
  `self-insert` coalescing. Favors append-only / persistent storage.
- Single-writer session event loop: all mutation is serialized, so we do **not**
  need lock-free concurrent writes. But cheap immutable snapshots for *readers*
  (render, tree-sitter, save, undo) are still very valuable.

Constraints summary that drive the choice:

| Constraint | Consequence for data structure |
| --- | --- |
| Immutable `buffer-model`, returns new versions | Favors persistent (structural-sharing) structures |
| Cheap snapshots for undo / SSE rev / bg tree-sitter | Strongly favors persistent rope or append-only piece table; disfavors gap buffer |
| Per-keystroke localized 1-char edits; paste = bulk | All candidates fine; not a reason to pick gap buffer |
| Hot path = coordinate conversions + line index + slice | Strongly favors a *summary*/augmented rope |
| Byte ↔ char ↔ UTF-16 ↔ line conversions everywhere | Favors per-node summary metadata (rope); piece tree needs extra work |
| Markers w/ insertion bias (byte offsets) | Structure-independent; keep external offsets |
| 1/10/100 MB benchmark gate | Rope & piece tree scale; string & gap-buffer-snapshot do not |
| Implemented in Racket CS | Custom chunked tree needed; treelist-as-rope known too slow |

---

## The candidates

### 1. Plain string (current) — the baseline to beat

- Single contiguous immutable string + side index vectors.
- Insert/delete: O(n) copy. Index rebuild: O(n) scan. Net **O(n) per keystroke**.
- Snapshot: free-ish (immutable string is shared) — this is the one thing it
  gets right, and the reason it has survived this long.
- Verdict: fine for the spike, not for v1. This is the structure we are replacing.

### 2. Gap buffer (Emacs, and the thing people reach for first)

- One contiguous array with an empty "gap" at the cursor. Typing fills the gap;
  the gap is moved by copying text across it.
- **Insert/delete at the gap: O(1) amortized.** Moving the gap: O(distance).
- Best cache locality of all options; sequential scans (render, search,
  highlight) are as fast as raw array iteration.
- Why it is *wrong for Weevil specifically*, despite the appealing per-keystroke
  story:
  - **Mutable in place.** It fights the immutable `buffer-model` and `struct-
    copy` design.
  - **Snapshots are O(n).** Undo, SSE revisions, and background tree-sitter all
    want a frozen buffer; with a gap buffer you must copy the whole thing each
    time. This is the opposite of what Weevil's architecture is built around.
  - Non-local editing patterns (multiple cursors, large jumps, scattered edits)
    degrade to O(distance) per edit because the gap must travel. Chris Wellons's
    well-known argument ("Gap Buffers Are Not Optimized for Multiple Cursors")
    captures this; the Core Dumped rebuttal shows it is less bad than folklore,
    but it is still a real cliff a rope does not have.
  - Large files: still one big allocation; line/column lookup needs a separate
    index anyway, so you do not even avoid the index machinery.
- Where it would win: a *single-user, in-place, local-only* editor that never
  needs cheap snapshots. That is not Weevil.

### 3. Piece table / piece tree (VS Code / Monaco)

- Two immutable byte buffers: the **original** (read-only, loaded file) and an
  **append-only "add" buffer** (everything you type). The document is an ordered
  sequence of **pieces** (descriptors: which buffer, start offset, length).
- Naive piece table keeps pieces in an array or linked list → O(P) per edit and
  O(P) line lookup, where P = number of pieces (grows with number of *non-
  consecutive* edits, not file size).
- **VS Code "piece tree"** (Peng Lyu, 2018) puts the pieces in a **red-black
  tree keyed on subtree metadata** (text length + newline count), giving
  O(log P) offset lookup and O(log P) line lookup, with line-start positions
  cached per node.
- Strengths (and why it is the strong runner-up):
  - Append-only buffers are inherently immutable → snapshot-friendly and a great
    fit for Weevil's model and the per-render revisioning.
  - **Undo is cheap and natural**: the original is never mutated and edits are
    just descriptors, so undo rewinds descriptor changes — no content snapshot.
    This is precisely the "server-owned, command-granularity undo" the ADR wants.
  - Excellent load time and memory: opening a 10 MB file uses ~10 MB for the
    (possibly mmap'd) original; the add buffer grows only by what you type. This
    is what made VS Code switch *to* it.
  - The keystroke model suits it: consecutive single-char inserts extend the
    same trailing piece in the add buffer rather than creating a piece per
    keystroke.
- Weaknesses (relative to the augmented rope):
  - **Fragmentation.** Over a long session, non-consecutive edits split pieces;
    P grows; substring/iteration slows. The `ocaml-piecerope` author notes piece
    trees "suffer from fragmentation problems because pieces can be extended only
    in the case of consecutive insertions," whereas ropes do not. Mitigation:
    periodic coalescing/compaction.
  - **Coordinate conversions.** The red-black tree indexes offset + line breaks;
    Weevil also needs char index and UTF-16 column. You can extend the per-node
    metadata to carry those, but at that point you are reinventing the rope's
    summary — so if you are going to carry rich summaries anyway, the rope is the
    cleaner home for them.
  - Two-buffer indirection makes slicing/iteration more complex than a rope's
    uniform chunks.

### 4. Rope, and specifically the augmented / SumTree rope (Zed, xi-editor, Helix/ropey)

- Classic rope: balanced binary tree; leaves hold short strings; each node
  stores the total length of its left subtree (its "weight"). Insert, delete,
  slice, concat, index are O(log n). Leaves are immutable; edits rewire a few
  nodes and share the rest.
- **Augmented rope ("SumTree" in Zed; monoid-summary rope in xi):** the tree is
  a B+-tree of bounded chunks (Zed: ≤128-byte `ArrayString` leaves; ropey: ~1KB
  leaves), and **every node carries a `Summary` of its subtree**. Zed's text
  summary carries, per node: UTF-8 length, UTF-16 length, line count + last-line
  length (as a `Point`), first/last line char counts, longest row, etc.
- The decisive feature: a **cursor can seek along one summary dimension and
  simultaneously read the aggregate of others, in O(log n)**. That means a
  single structure answers, all in O(log n):
  - offset → (line, column)  (`offset_to_point`)
  - (line, column) → offset  (`point_to_offset`)
  - UTF-8 point → UTF-16 point (the LSP/browser conversion)
  - "give me line N's range" / total line count / longest line (scrollbar)
  - slice the visible byte/line range for rendering
  This is **exactly the set of conversions Weevil computes today with O(n) scans
  in `position.rkt` and the O(n) index rebuild in `buffer-model.rkt`.** The rope
  replaces both the string *and* the two line-start vectors with one structure
  that maintains all of it incrementally.
- Persistence: structural sharing + reference counting → **O(1) snapshots**.
  Zed sends a snapshot to a background tree-sitter thread on *every* edit
  precisely because it is free. This is the property Weevil needs for background
  parsing, undo, and SSE revisions.
- Performance character (per ropey's author, quoted by Zed): ropes are "a jack
  of all trades — not amazing at anything, but always solidly good with O(log N)
  performance," and "degrade" gracefully where gap buffers "degrade poorly with
  unfavorable editing patterns." For an editor that wants flexibility (multiple
  cursors, scattered edits, large files, background readers), that consistency
  is the point.
- Cost: most complex to implement correctly (balancing, splitting chunks on
  codepoint boundaries, summary plumbing). And in Racket the constant factors
  matter — see the Racket note below.

### 5. Others (surveyed, not recommended)

- **Array-of-lines / linked-list-of-lines.** Cache-friendly for line navigation;
  used historically and (in elaborated form) by Vim/Neovim. Two problems:
  pathological very-long lines degrade to the flat-array case *within* a line,
  and per-line allocations/copies get expensive for large documents. Monaco used
  array-of-lines for years and *left* it for the piece tree due to memory and
  performance. Bad fit for Weevil's Unicode-column + immutable needs.
- **Vim/Neovim `memline`.** A B-tree of line blocks backed by a memory-mapped
  file (`memfile`), with pointer blocks and data blocks, designed for huge files
  and crash recovery via paging to disk. Impressive, but it is a mutable, file-
  backed design oriented around swap/recovery, not around cheap in-memory
  immutable snapshots. Not aligned with Weevil v1.
- **CRDT rope (xi-editor).** xi's rope is a monoid-summary rope underneath, with
  a CRDT layer on top for decentralized collaborative editing. The *rope* part
  is exactly our candidate #4; the *CRDT* part is collaboration machinery Weevil
  does not need in v1 (no stated multi-user requirement). Borrow the rope, skip
  the CRDT.

---

## Comparison at a glance

| Property (for Weevil's needs) | String (now) | Gap buffer | Piece tree | Augmented rope |
| --- | --- | --- | --- | --- |
| 1-char insert/delete at point | O(n) | O(1)* amortized | O(log P) | O(log n) |
| Non-local / scattered edits | O(n) | O(distance) | O(log P) | O(log n) |
| Bulk paste (m chars) | O(n) | O(n+m) | O(log P + m) | O(log n + m) |
| Line N lookup / line count | O(log) via side vec | needs side index | O(log P) | O(log n) |
| byte↔char↔UTF-16↔line conversions | O(n) scans now | needs side index | extra metadata needed | **O(log n) built-in** |
| Slice visible range (render) | O(n)+rebuild | O(range) | O(range) | O(log n + range) |
| Immutable snapshot (undo/SSE/parse) | cheap (shared) | **O(n) copy** | cheap (append-only) | **O(1) (shared)** |
| Memory on large file | 1 string | 1 array + gap | original + adds | chunks (no fragmentation) |
| Fragments over long session | no | no | **yes (needs coalesce)** | no |
| Fits immutable `buffer-model` | yes (but slow) | no | yes | **yes** |
| Implementation complexity | trivial | low | medium | **high** |

\* Gap buffer O(1) insert assumes the gap is already at point; otherwise add the
gap-move cost O(distance).

---

## Recommendation for Weevil

**Adopt an augmented, persistent rope (SumTree-style) as the v1 target storage,
behind the existing `buffer-model` API.** Treat the **piece tree** as the
fallback if rope implementation/benchmark effort in Racket proves too costly.

Rationale, ranked by how much it matters here:

1. It is the only candidate that makes the *currently most expensive recurring
   work* — line indexing and byte/char/UTF-16/line conversions on every render —
   O(log n) inside one structure, replacing both the string and the two
   line-start vectors and the O(n) `position.rkt` scans.
2. It is persistent, so it matches the immutable `buffer-model` and gives O(1)
   snapshots for undo, SSE revisions, and background tree-sitter — capabilities
   the architecture already assumes.
3. It has no editing-pattern cliffs (multiple cursors, scattered edits, huge
   files all stay O(log n)) and no session-long fragmentation.

Why not just the piece tree (the runner-up): it shares the immutability/undo/
memory wins, but it would still need rope-like per-node summaries bolted on to
serve Weevil's char/UTF-16/line conversions, and it fragments. If you are going
to maintain rich summaries anyway, the rope is the cleaner structure to put them
in. The piece tree remains attractive if (a) load time / memory of very large
read-mostly files becomes a headline feature, or (b) the rope proves too slow to
implement well in Racket and we want a simpler append-only structure fast.

### Concrete shape (ties into current code)

- Replace `(struct buffer-model (text line-starts line-start-bytes))` with a
  chunked persistent tree. Each node summary carries what `position.rkt` /
  `buffer-model.rkt` compute today, maintained incrementally:
  - UTF-8 byte length, char length, UTF-16 code-unit length
  - newline count (= line count contribution) and last-line lengths (for column
    math and "longest line" if we want a horizontal scrollbar later)
- **Keep the public model API identical**: `buffer-model-insert`,
  `-delete`, `-backspace`, `-byte->char`, `-char->byte`, `-line-count`,
  `-byte->line/utf16-column`, `-line/utf16-column->byte`, etc. `buffer-text-
  state` already wraps the model, and `buffer-state` keeps text one level deeper,
  so this is a pure internal swap. Callers in `session-state.rkt` /
  `editor-state.rkt` do not change.
- Leaf chunk size: start in the ~256–1024 byte range (Zed uses ~128 chars,
  ropey ~1KB); tune by benchmark. Always split on UTF-8 codepoint boundaries so
  a leaf never holds a partial codepoint (the model already validates codepoint
  boundaries).
- **Coalesce consecutive `self-insert`** into the active (rightmost-touched)
  leaf so typing a word does not allocate a node per keystroke — the same spirit
  as the undo coalescing the ADR already specifies.
- **Markers** stay external byte offsets adjusted by edit deltas (current
  `marker-state` logic is fine and structure-independent).
- **Undo** with a persistent rope can simply retain the previous root reference
  (structural sharing makes that cheap) and/or store inverse edits; either way
  no full-content snapshot.

### Phased plan (honors the ADR benchmark gate)

The ADR's "Buffer Representation and Benchmark Gate" requires benchmarking
open / insert / delete / line-lookup / slice / undo / save against 1/10/100 MB
before setting v1 large-file claims. **There are currently no benchmarks in
`tests/`.** So:

- **Phase A — interface + benchmark harness (do first).** Formalize the storage
  interface (the existing `buffer-model` functions already are it) and add a
  benchmark harness covering the gate operations at 1/10/100 MB across realistic
  patterns: localized typing, scattered edits, one very long line, large paste,
  visible-range slicing, repeated undo. This harness is required regardless of
  which structure wins.
- **Phase B — implement the augmented rope behind the same API**, keeping the
  string implementation for **differential / property testing** (random edit
  sequences must produce identical text and identical conversions on both).
- **Phase C — benchmark both in Racket CS, then decide.** If the rope clears the
  gate, ship it and set public large-file claims from the numbers. If Racket
  constant factors make it underperform, fall back to the piece tree (also
  implemented behind the same API).

### Racket-specific cautions

- **Do not assume `treelist` (RRB vector) solves this.** `racket-langserver`
  built a textbuffer on a treelist-based rope and reported it was *"still too
  slow for big files,"* then renamed the PR from "treelist based textbuffer" to
  "immutable rope based textbuffer" and shipped a hand-rolled immutable rope.
  Treelist is a great *general* sequence (O(log n) index/insert/split/append) and
  is worth trying for the chunk-sequence layer, but plan for a custom node tree
  with bytewise/stringwise chunked leaves and cached summaries, and verify with
  the benchmark harness — not by analogy to Rust ropes.
- Prior art that exists in the Lisp/Scheme world to study: `dyoo/rope.plt`
  (Racket PLaneT rope, Boehm-Atkinson-Plass style), the CHICKEN Scheme `rope`
  egg, and the `racket-langserver` immutable rope. None are summary ropes, but
  they show the leaf/tree mechanics in-language.
- Racket strings are immutable and shareable, which means leaf chunks (small
  substrings) are cheap to share and the persistence story is natural.

---

## Sources

Comparisons & surveys
- Core Dumped, "Text showdown: Gap Buffers vs Ropes" —
  https://coredumped.dev/2023/08/09/text-showdown-gap-buffers-vs-ropes/
- Gaurav Sarma, "Text editor data structures" —
  https://www.gauravsarma.com/posts/2026-04-05_text-editor-data-structures
- 0xKiire, "Text Editor Data Structures: Gap Buffers, Ropes" —
  https://0xkiire.com/text_editor_data_structures(1)/
- Crowley, "Data Structures for Text Sequences" (the piece-table paper) —
  https://www.cs.unm.edu/~crowley/papers/sds.pdf
- Good Math Bad Math, "Gap Buffers, or, Don't Get Tied Up With Ropes?" —
  https://goodmath.scientopia.org/2009/02/18/gap-buffers-or-dont-get-tied-up-with-ropes/

Gap buffers
- Chris Wellons, "Gap Buffers Are Not Optimized for Multiple Cursors" —
  https://nullprogram.com/blog/2017/09/07/
- Wikipedia, "Gap buffer" — https://en.wikipedia.org/wiki/Gap_buffer

Piece table / piece tree
- VS Code, "Text Buffer Reimplementation" (the piece tree rationale) —
  https://code.visualstudio.com/blogs/2018/03/23/text-buffer-reimplementation
- VS Code PR #41172, "buffer improvement with piece tree" —
  https://github.com/Microsoft/vscode/pull/41172
- vscode-textbuffer issue #1, "Immutability and infinite undo/redo stack" —
  https://github.com/microsoft/vscode-textbuffer/issues/1
- martanne/vis wiki, "Text management using a piece chain" —
  https://github.com/martanne/vis/wiki/Text-management-using-a-piece-chain
- catch22, "Piece Chains" — https://www.catch22.net/tuts/neatpad/piece-chains/
- hummy123/ocaml-piecerope (fragmentation vs ropes) —
  https://github.com/hummy123/ocaml-piecerope

Ropes (esp. augmented / SumTree)
- Zed, "Rope & SumTree" —
  https://zed.dev/blog/zed-decoded-rope-sumtree
- Zed, "Rope Optimizations, Part 1" —
  https://zed.dev/blog/zed-decoded-rope-optimizations-part-1
- cessen/ropey — https://github.com/cessen/ropey
- noib3/crop — https://github.com/noib3/crop
- xi-editor rope science / CRDT details —
  https://xi-editor.io/docs/crdt-details.html
- Boehm, Atkinson, Plass, "Ropes: an Alternative to Strings" —
  https://www.cs.tufts.edu/comp/150FP/archive/hans-boehm/ropes.pdf
- AvalonEdit issue #381, rope vs piece table benchmark —
  https://github.com/icsharpcode/AvalonEdit/issues/381

Racket-specific
- racket-langserver PR #201, "Add an immutable rope based textbuffer"
  (treelist rope "too slow for big files") —
  https://github.com/jeapostrophe/racket-langserver/pull/201
- Racket `treelist` docs — https://download.racket-lang.org/releases/9.1/doc/reference/treelist.html
- RRB vector paper (Stucki et al.) —
  https://infoscience.epfl.ch/record/213452/files/rrbvector.pdf
- dyoo/rope.plt (Racket rope) —
  https://planet.racket-lang.org/package-source/dyoo/rope.plt/1/1/doc.txt
- CHICKEN Scheme `rope` egg — http://wiki.call-cc.org/eggref/5/rope

tree-sitter integration (why cheap snapshots matter)
- tree-sitter advanced parsing (incremental edits via byte ranges) —
  https://tree-sitter.github.io/tree-sitter/using-parsers#advanced-parsing

Other editors surveyed
- Neovim `memline` (tree of line blocks, file-backed) —
  https://github.com/neovim/neovim/blob/master/src/nvim/memline.c
- Neovim dev architecture — https://neovim.io/doc/user/dev_arch/
