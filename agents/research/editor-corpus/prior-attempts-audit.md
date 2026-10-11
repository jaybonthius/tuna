# Prior buffer and editor attempts: audit

Status: historical synthesis. This is not a storage decision or implementation
plan.

## Bottom line

The old work established several valuable invariants, but it repeatedly mixed
four different concerns:

1. the editor-level buffer and its Emacs-like metadata;
2. the private text-store data structure;
3. per-view point, selection, and scrolling state;
4. the server-rendered display projection.

The most reusable result is therefore not “use a gap buffer” or “use a rope.” It
is the need for a narrow, opaque text-store seam underneath a separately modeled
editor buffer, with editor operations coordinating text changes, anchors, undo,
views, and rendering.

Two serious Racket implementations produced conflicting evidence:

- old Tuna's mutable gap buffer had excellent edit latency and a carefully tested
  rollback story, but cold whole-buffer snapshots and long-line coordinate scans
  remained linear and allocation-heavy;
- Weevil's augmented persistent rope produced cheap retained snapshots and flat
  large-file editing/conversion scaling, but had higher implementation
  complexity and showed how editor policy can leak into a nominal storage API.

The current `tuna-racket` runtime differs from both attempts. It publishes one
revisioned application root but does not enforce transitive immutability.
Storage must be selected against the eventual editor update, undo, parsing, and
rendering path rather than inherited from either project.

## What was tried

### 1. A feature-inventory buffer record

An early Tuna revision placed text, file state, modes, markers, undo, and
overlays into one record before those facilities had behavior contracts or
tests. That shape was later reduced to buffer identity and file metadata, with
text moved behind a private adapter.

Lesson: a list of future Emacs features is not yet a coherent object boundary.
Text, modes, properties, overlays, markers, undo, file identity, and view state
have different sharing and lifecycle rules.

Historical source:

- Tuna revision `0b7d71f`, `tuna/buffer.rkt:8-32`;
- Tuna revision `eb45989`, `tuna/core/buffer.rkt:5-21`.

### 2. A generic persistent SumTree subsystem

The unmerged Tuna SumTree attempt built three layers:

```text
generic persistent measured sequence
  → UTF-8 summarized text
    → editor text/revision/change-set API
```

It implemented immutable B+ trees, root-bound cursors, summary-directed seeking,
normalized batches, retained roots, Unicode coordinate conversions, and generic
non-text adapters. Its tests covered structural invariants, failure behavior,
subtree sharing, randomized differential edits, scalar boundaries, old-snapshot
batch ordering, property runs, overlays, and independent anchors.

That work was real and broad, not merely a proposal. It also became a subsystem
before a small editor behavior required the generic surface. The splice engine,
text adapter, benchmark framework, public revisions, public change sets, and
approval/report machinery all grew together.

The matched benchmark was decisive for that implementation:

- SumTree local trace median: about `2015 ms`;
- matched mutable-gap edit median: about `2.96 ms`;
- ratio: about `680×`.

The tree also fragmented during local editing and required explicit rebuilding.
No explicit abandonment postmortem was found, but the performance result and
scope growth are material evidence.

Preserved sources:

- [`prior-art/tuna-stashed-sum-tree/docs/plans/sum-tree-buffer-plan.md`](prior-art/tuna-stashed-sum-tree/docs/plans/sum-tree-buffer-plan.md)
- [`prior-art/tuna-stashed-sum-tree/docs/research/sum-tree-benchmark.md`](prior-art/tuna-stashed-sum-tree/docs/research/sum-tree-benchmark.md)
- [`prior-art/tuna-stashed-sum-tree/sum-tree-docs/performance.md`](prior-art/tuna-stashed-sum-tree/sum-tree-docs/performance.md)

The failure was not proof that persistent trees are unsuitable for Racket. It
was proof that this generic tree/text implementation did not satisfy the local
edit workload at acceptable cost.

### 3. Tuna's landed mutable gap buffer

The later Tuna implementation deliberately narrowed the private text store to a
mutable UTF-8 byte gap plus a separate gap-vector LF line index. Its physical
coordinates never crossed the module boundary. It supported:

- exact scalar-aligned UTF-8 byte offsets;
- LF-only line semantics;
- character and UTF-16 location conversion;
- old-text batch edits with deterministic boundary ordering;
- immutable full/range reads;
- prevalidated, preallocated splices;
- rollback after exceptions, breaks, and nonlocal exits;
- one-shot reversal handles used only for update cancellation.

The editor buffer and text store were separate. Immutable editor metadata kept
`buffer` and `view` records; the runtime owned a map from buffer ID to mutable
`buffer-content`. A text edit mutated the private store reversibly and mapped
all view points in the same outer update.

Preserved sources:

- [`prior-art/tuna/docs/plans/gap-buffer-plan.md`](prior-art/tuna/docs/plans/gap-buffer-plan.md)
- [`prior-art/tuna/docs/plans/editable-buffer-api-plan.md`](prior-art/tuna/docs/plans/editable-buffer-api-plan.md)
- [`prior-art/tuna/docs/adr/0002-runtime-owned-subject-text.md`](prior-art/tuna/docs/adr/0002-runtime-owned-subject-text.md)
- [`prior-art/tuna/docs/research/gap-buffer-benchmark.md`](prior-art/tuna/docs/research/gap-buffer-benchmark.md)

The pinned-host benchmark passed every gate. Representative results were:

- 20,000 local edits: about `29 ms` total;
- local 10 MiB edit p99: about `0.004 ms`;
- far edit across 100 MiB p99: about `6.1 ms`;
- 10,000 scattered edits in 10 MiB: about `6.6 ms`;
- cold 100 MiB snapshot: about `105 ms` and about `200 MiB` allocation.

The intentionally visible weakness was a 10 MiB single-line coordinate case:
about `197 ms` and `672 MiB` allocation. The line-start index avoids whole-file
line scans, but locating within one enormous line is still linear.

The integration also exposed architectural costs:

- mutable text outside the immutable editor root required a sophisticated
  cancellation journal;
- rendering a cold complete snapshot while holding the editor lock could block
  other work;
- text was intentionally not persisted, so restored buffers became empty;
- successful no-op edit calls still emitted the generic change event;
- the cancellation journal was rollback machinery, not user undo.

### 4. Weevil's augmented persistent rope

Weevil first researched whole strings, gap buffers, piece trees, and ropes, then
implemented a specialized persistent UTF-8 rope. The tree used bounded chunks
and cached subtree summaries for bytes, codepoints, UTF-16 units, LF count, and
last-line width. A simple whole-string backend remained as a differential-test
oracle.

Preserved sources:

- [`prior-art/weevil/plans/archive/buffer-data-structure-research.md`](prior-art/weevil/plans/archive/buffer-data-structure-research.md)
- [`prior-art/weevil/plans/archive/buffer-rope-implementation-plan.md`](prior-art/weevil/plans/archive/buffer-rope-implementation-plan.md)
- [`prior-art/weevil/plans/archive/buffer-rope-benchmark-results.md`](prior-art/weevil/plans/archive/buffer-rope-benchmark-results.md)
- [`prior-art/weevil/plans/rope-package-extraction-2026-06-22.md`](prior-art/weevil/plans/rope-package-extraction-2026-06-22.md)
- [`prior-art/weevil/plans/review-2026-06/03-core-buffer-model.md`](prior-art/weevil/plans/review-2026-06/03-core-buffer-model.md)

The durable benchmark result was scaling shape, not machine-specific latency:

- whole-string insert/delete cost grew roughly linearly from 1 to 10 MiB;
- rope insert/delete remained essentially flat;
- coordinate conversion and visible-range slicing stayed small;
- retained snapshots shared structure cheaply;
- whole-buffer serialization became an expected O(n) rope cost.

At 100 MiB, the archived run reported sub-millisecond midpoint insertion,
small visible-window slices, and roughly one-second open/save materialization.
The rope's standalone and differential tests covered Unicode, CRLF, random edits,
coordinate round trips, line slices, and structural invariants.

The implementation audit found important limitations:

- the 25-operation “storage” API also owned word motion, beginning/end-of-line,
  and backspace policy;
- marker adjustment code existed but was not connected to the edit path;
- a `text-id` indirection suggested shared text, but editing one buffer did not
  update another buffer carrying the same ID;
- display segments mixed byte ranges, codepoint columns, and line-local
  coordinates;
- the display-to-content mapping remained a placeholder;
- the text provider and dispatcher formed a dependency cycle;
- main-buffer and minibuffer rendering retained two cursor/projection pipelines.

Lesson: persistence and summary metadata can work well in Racket, but the text
store must not absorb mode-sensitive motion, command behavior, markers, or
rendering policy.

### 5. Server-owned rendering and UI models

Old Tuna and Weevil both converged on Racket/server authority and HTML as a
projection. They also repeatedly coupled editor semantics to a particular
presentation shape:

- a whole buffer rendered as one text flow;
- then a line-based provider;
- then special providers for terminal content;
- separate minibuffer paths;
- layout trees that risked becoming content trees;
- exact-output goldens that protected refactors but made legitimate DOM evolution
  costly.

Weevil's projection seam remains useful: request visible content, cursor, and
decorations without making the DOM authoritative. Its line-based protocol is
not a sufficient universal model for Tuna's proposed structural content tree.

Preserved sources:

- [`prior-art/weevil/plans/archive/display-projection-plan.md`](prior-art/weevil/plans/archive/display-projection-plan.md)
- [`prior-art/weevil/plans/archive/cursor-overlay-plan.md`](prior-art/weevil/plans/archive/cursor-overlay-plan.md)
- [`prior-art/tuna/.scratch/rendering-views/working-notes.md`](prior-art/tuna/.scratch/rendering-views/working-notes.md)
- [`prior-art/workbench-gerbil/research/tuna-integrated-web-application-shape.md`](prior-art/workbench-gerbil/research/tuna-integrated-web-application-shape.md)

## Conflicting choices that remain open

| Question | Tuna attempt | Weevil attempt | Why Tuna cannot inherit either answer yet |
|---|---|---|---|
| Text mutation | Mutable gap buffer | Persistent rope | Current root/undo/render/parser requirements are not settled |
| Snapshot | Cached O(n) copy after edit | O(1) retained root | Snapshot frequency and lifetime are unknown |
| Rollback | Prepared inverse splices | Discard unpublished immutable roots | Structural tree and multi-leaf transaction model is unknown |
| Public position | Exact 0-based UTF-8 bytes | 1-based characters, private bytes | Extension-facing compatibility has not been chosen |
| Text identity | One runtime text store per buffer ID | Separate-looking text holder, incomplete sharing | Rich outer buffers may own several leaves or share text |
| Modes | Planned per buffer | IDs/keymaps per buffer | Owner wants possible subtree/leaf-dependent behavior |
| Projection | Complete text per layout leaf | Visible line provider | Rich structured content cannot be flattened prematurely |
| Persistence | Buffer metadata only; text reset | Persistent roots useful for undo, not necessarily disk | File/session/recovery policy remains open |

## What should be preserved

1. **Terminology boundary:** editor buffer, view, editable text leaf, and text
   store are different things.
2. **Opaque representation:** no public API should expose gaps, rope chunks,
   tree nodes, piece descriptors, or physical coordinates.
3. **Exact text semantics:** specify Unicode boundaries, newline policy,
   coordinate systems, half-open ranges, and equal-position edit ordering before
   optimizing.
4. **Simple oracle:** keep an obviously correct reference model and randomized
   differential tests for every candidate representation.
5. **Workload-driven benchmarks:** include localized typing, far/scattered edits,
   paste, very long lines, conversions, visible slicing, full serialization,
   and retained snapshots.
6. **Measure consumers:** benchmark actual edit plus anchor mapping, undo,
   parsing snapshot, and render slicing—not the data structure alone.
7. **Change delta above storage:** editor operations need enough edit information
   to update markers, properties, overlays, views, undo, dirty state, and
   invalidation atomically.
8. **Projection boundary:** HTML/CSS and the DOM remain derived; text content is
   escaped data unless trusted configuration explicitly creates semantic
   structural nodes.
9. **One writer:** current Tuna's serialized state owner is a strong coordination
   boundary, but all mutable text aliases must participate in it.

## Patterns not to repeat

- building a generic sequence framework before one editor behavior needs it;
- exposing revisions, change sets, cursors, or provider protocols merely because
  an internal implementation has them;
- putting word syntax, command motion, or mode policy in the storage backend;
- treating tested-but-disconnected marker helpers as a functioning anchor model;
- adding separate special state paths for minibuffers, terminals, popups, or
  structured views instead of first checking whether ordinary buffer/tree
  concepts can compose;
- creating a second canonical layout/UI tree beside an existing one;
- assuming full-document rendering or exact DOM output is a permanent editor
  contract;
- treating command rollback, user undo, persistence, and recovery as one log;
- copying benchmark latency claims across hardware or across different render
  and state architectures.

## Evaluation criteria for future editing proposals

A future proposal should explain whether its private behavioral seam could be
satisfied by more than one representation, and why representation details do or
do not need to escape it. Review should distinguish storage operations such as
splicing, range traversal, metrics, and coordinate conversion from editor-level
modes, markers, undo, syntax, and rendering policy.

The unresolved scope, undo, input, and UI-tree questions used to evaluate such a
proposal are cataloged in [`research-gaps.md`](research-gaps.md).
