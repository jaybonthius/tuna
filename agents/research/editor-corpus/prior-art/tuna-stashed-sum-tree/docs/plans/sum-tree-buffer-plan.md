# SumTree and editable buffer plan

## Status

Proposed for review.

## Decision

Build a sibling `sum-tree/` collection whose public abstraction is an
immutable, persistent **measured sequence**. Its implementation is a wide
augmented B+ tree. The collection is Tuna-agnostic and text-agnostic; it depends
only on `racket/base` and never imports Tuna. `sum-tree` is a collection inside
the repository's existing multi-collection package, not a separately installed
Racket package.

Build Tuna's text and buffer modules above that seam:

```text
sum-tree measured sequence
          ^
          |
Tuna UTF-8 text + coordinate adapter
          ^
          |
Tuna buffer + edit transaction/change set
          ^
          |
views, modes, undo, markers, overlays, syntax, rendering
```

This is intentionally not one universal “buffer tree.” Text, text-property
runs, interval annotations, undo, modes, files, and views have different
semantics and lifetimes. They may reuse the same measured-sequence mechanism,
but Tuna composes them at the buffer seam.

Use a SumTree rather than a gap buffer as the primary candidate because Tuna
requires cheap immutable snapshots, summary-based coordinate conversion, and
scattered batch edits. Do not claim it is faster from asymptotics or from Zed's
Rust implementation. Racket CS benchmarks are an implementation gate.

## Calls made

1. **The reusable collection is generic.** Do not put `buffer`, `text`,
   Unicode, markers, overlays, files, modes, revisions, or editor events in
   `sum-tree`.
2. **The public abstraction is a measured sequence, not tree topology.** Nodes,
   fanout, chunks, balancing, mutable builders, and sharing strategy are private.
3. **Values are persistent.** Every transformation returns a new root; every old
   root and cursor into that root remains readable.
4. **Batch splice is a primitive.** Multicursor editing must not be implemented
   as a loop of public single edits.
5. **Summaries are pure and context-free.** Tuna will not copy Zed's mutable or
   ambient `Context` mechanism. A tree retains one exact measure descriptor;
   trees with different descriptors cannot be combined.
6. **Seek uses the complete accumulated summary.** Do not reproduce Zed's Rust
   trait and tuple-dimension surface. A target compares against prefix summaries;
   the returned cursor exposes the complete prefix summary, so one descent can
   locate by bytes while also accumulating characters, lines, or UTF-16 units.
7. **SumTree cursors are snapshot positions, not durable anchors.** Cross-edit
   affinity, deletion collapse, revision translation, and identity belong to
   Tuna's buffer layer.
8. **Text properties and overlays remain distinct.** Sequence-aligned,
   non-overlapping property runs fit another measured sequence. Arbitrarily
   overlapping overlays require a dedicated interval index and must not be
   stuffed into text summaries.
9. **Buffers are Tuna's displayed content objects.** The target editor state
   has buffers and views; a view points directly to a buffer. Terminal, Git,
   minibuffer, and ordinary file content all use buffers rather than a second
   generic subject abstraction.
10. **View state is not buffer content.** Primary point, mark, selections,
    viewport, scroll, and an accessible/narrowed range belong to a view. Text,
    revision, modes, file backing, undo, process marks, and buffer-scoped
    annotations belong to a buffer.
11. **There is no separate document entity in this milestone.** Multiple views
    share one buffer and its editing context. This deliberately does not model
    Emacs indirect buffers with independent modes/overlays over shared text. A
    document/buffer split is justified only when Tuna has that production use
    case; adding it now would impose an extra identity and fan-out protocol on
    every ordinary buffer.
12. **Interactive commands run with an explicit view context.** View narrowing
    constrains those commands. Headless buffer operations take explicit ranges
    and otherwise address the full buffer, so they do not depend on a hidden
    point or restriction.

## Research conclusions

### GNU Emacs

Emacs demonstrates the semantic breadth that must be accounted for, but not the
representation Tuna should copy.

- `buffer_text` owns shared character storage, text-property intervals,
  modification bookkeeping, and the head of the marker chain.
- `struct buffer` owns editing-context state such as point/restriction, local
  modes and variables, an overlay interval tree, and other display/file policy.
- Base and indirect buffers share characters and text properties. Marker
  objects, overlays, point, narrowing, modes, and locals are buffer-specific,
  even though a shared-text edit relocates positions for every participating
  buffer.
- Text properties are content-attached, sticky range runs and copy with text.
  Overlays are separately identified interval objects, do not copy with text,
  and have endpoint affinity, priority, and lifecycle behavior.
- Font Lock/JIT Lock and syntax parsing are invalidation pipelines. Their
  derived results are not all canonical buffer truth and should not force a
  synchronous full-buffer pass after every edit.
- Emacs's single movable gap is excellent for localized typing but must copy the
  distance traversed when edits jump. Its marker and annotation work can also
  dominate a nominally small text edit.
- Point is nuanced when several windows show one buffer; the selected window
  uses buffer point while nonselected windows retain window point. Tuna should
  make cursor state unambiguously per-view.
- Emacs does not establish one mandatory shared-undo model for indirect
  buffers. Tuna chooses one buffer-wide transaction history because multiple
  views edit one Tuna buffer.

The requirement to preserve is therefore a shared editable text snapshot with
tracked positions, range metadata, batched changes, independent views, derived
invalidation, and explicit history—not Emacs's C field layout, gap, marker
list, or property names.

### Zed

Zed validates the usefulness of a persistent measured wide tree, not a direct
port.

- `SumTree<T>` is a copy-on-write B+ tree with cached ordered summaries,
  summary-directed seeking, biased boundaries, and path-local rebuilding.
- Zed's rope is a SumTree of chunks whose summaries carry byte, UTF-16, and line
  information.
- Zed's buffer then adds CRDT fragments, anchors, clocks, versions,
  transactions, deleted text, and more SumTrees. Those facilities do not come
  “for free” with a SumTree.
- Its batch buffer edit converts all ranges against the pre-edit snapshot and
  walks forward through ordered edits. That is the transferable multicursor
  lesson.
- Reusing an ordered cursor matters: Zed has fixed a quadratic display-map path
  by avoiding repeated root traversals. Tuna's batch paths must likewise reuse
  one forward cursor.
- Zed provides no reproducible first-party benchmark showing a numeric
  multicursor advantage. Its fanout, chunk size, `Arc::make_mut`, Rust traits,
  and CRDT identities are not Racket design evidence.

The user-provided [`zed-sum-tree`](https://crates.io/crates/zed-sum-tree)
0.2.0 crate is useful corroboration, not a specification. It is an Apache-2.0
publication with Zed-owned registry provenance and source matching Zed commit
`e317d98915224105b148c43edd7b788f334e1317`; the crate metadata contains no
repository/tag/VCS attestation, so that commit is matching-source evidence, not
a proven release commit. Its API exposes nodes, mutable copy-on-write methods,
contextual summaries, keyed edits, maps, and sets. It has no normalized range
batch splice, editor transaction, durable anchor, overlap policy, or benchmark
results. Its keyed batch edit nevertheless reinforces the useful rule: sort or
validate at the owning layer, then rebuild with one forward cursor.

### Other structures

- A gap buffer is the local-edit baseline, not the chosen snapshot model.
- A binary rope has the desired asymptotics but more pointer depth than a packed
  wide tree.
- [Ropey](https://crates.io/crates/ropey) 1.6.1 is strong production evidence
  for a text-specialized wide B-tree with roughly half-full occupancy, inline
  bounded UTF-8 chunks, cached byte/character/line-break facts plus surrogate
  counts used for UTF-16 conversion, copy-on-write roots, underflow repair, and
  fragmentation compaction. It is not a generic
  measured sequence and has no simultaneous batch-edit primitive. Its borrowed
  slices, character-indexed edits, interior-coordinate rounding, and
  CR/CRLF/Unicode-line policy are deliberately not Tuna semantics.
- A piece tree remains a credible text adapter over the same measured-sequence
  seam, especially if immutable original/add storage wins the Racket benchmark.
- A measured finger tree is the functional control, but its allocation and
  locality relative to a packed B+ tree must be measured.
- An interval tree complements the sequence tree for arbitrary overlap queries.
- A CRDT is unjustified without concurrent replica merge requirements.

## Module seams

### `sum-tree`: persistent measured sequence

`sum-tree` owns:

- packed construction;
- ordered item storage;
- cached subtree summaries;
- item-count navigation;
- prefix-summary seeking with left/right boundary bias;
- snapshot-bound forward/backward cursors;
- range summaries;
- normalized batch splice;
- balancing, structural sharing, and private builders;
- invariant checks, differential tests, and data-structure benchmarks.

`sum-tree` does not own:

- positions inside an item;
- text chunks or encodings;
- cross-version anchors;
- edit conflict or overlap policy beyond validating its normalized input;
- interval-object semantics;
- transactions, undo, notifications, or persistence formats;
- buffer, view, file, mode, syntax, rendering, or collaboration concepts.

### Tuna text

Tuna text owns:

- valid UTF-8 chunk or piece items;
- splitting at Unicode scalar boundaries;
- byte, character, UTF-16, line, and line-column summaries;
- conversion among those coordinates;
- text slicing and serialization;
- simultaneous text edits expressed in old-snapshot byte coordinates;
- a normalized text change set describing old and new spans.

The text module hides `sum-tree?`, chunks, summaries, and cursors from Tuna's
public buffer interface.

### Tuna buffer

A buffer owns the shared editing context:

```racket
(struct buffer (id text revision file))
```

The initial buffer milestone keeps this record small. Modes, buffer-local
values, undo, file fingerprints, and annotations attach here when their roadmap
items are implemented; they do not enter `sum-tree`.

A view names one buffer:

```racket
(struct view (id buffer-id))
```

The following view milestone adds cursors, selections, viewport, and accessible
range to the view rather than the buffer text.

## Generic SumTree interface

The collection uses the full kebab-case `sum-tree` spelling. Public records are
immutable; trees, specs, and cursors are opaque.

```racket
sum-tree-spec?
sum-tree?
sum-tree-cursor?

(make-sum-tree-spec
 #:summary? summary?
 #:zero zero-summary
 #:summarize item->summary
 #:combine combine-summaries)
; (->* (#:summary? (-> any/c boolean?)
;        #:zero any/c
;        #:summarize (-> any/c any/c)
;        #:combine (-> any/c any/c any/c))
;       ()
;       sum-tree-spec?)

sum-tree-empty                       ; spec -> tree
list->sum-tree                       ; spec list? -> tree
vector->sum-tree                     ; spec vector? -> tree
sum-tree-empty?                      ; tree -> boolean?
sum-tree-count                       ; tree -> exact-nonnegative-integer?
sum-tree-summary                     ; tree -> summary
in-sum-tree                          ; tree -> sequence?

sum-tree-cursor                      ; tree [index] -> cursor
sum-tree-cursor-seek-index!          ; cursor index -> void?
sum-tree-cursor-seek!                ; cursor comparator #:bias bias -> void?
sum-tree-cursor-seek-forward!        ; cursor comparator #:bias bias -> void?
sum-tree-cursor-next!                ; cursor -> boolean?
sum-tree-cursor-prev!                ; cursor -> boolean?
sum-tree-cursor-index                ; cursor -> exact-nonnegative-integer?
sum-tree-cursor-prefix-summary       ; cursor -> summary
sum-tree-cursor-at-start?            ; cursor -> boolean?
sum-tree-cursor-at-end?              ; cursor -> boolean?
sum-tree-cursor-left-item            ; cursor -> item; raises at start
sum-tree-cursor-right-item           ; cursor -> item; raises at end

sum-tree-range-summary               ; tree start-index end-index -> summary
(struct sum-tree-edit (start end replacement) #:transparent)
sum-tree-splice                      ; tree start end replacement-tree -> tree
sum-tree-splice*                     ; tree (listof sum-tree-edit?) -> tree
```

Indexes are exact nonnegative integers. A prefix comparator has contract
`(-> summary (or/c 'before 'at 'after))`; bias is `(or/c 'left 'right)`.
The transparent edit declaration exports `sum-tree-edit?` and all three field
accessors. Every replacement is a `sum-tree?`, not a list or lazy sequence.

`list->sum-tree` and `vector->sum-tree` accept finite proper containers. The
package does not consume an arbitrary sequence that may be infinite. A
`sum-tree-edit` is a transparent immutable record containing two item-boundary
indexes and a replacement `sum-tree` built with the exact same `eq?` spec.
`sum-tree-splice` and `sum-tree-splice*` return one new tree. An empty edit list
returns the input tree by identity. Every public shape/range/spec error raises
`exn:fail:contract?`; an exception from a client summary procedure propagates
without changing any published root.

A cursor denotes a physical gap with index in `[0, count]`. Its prefix summary
covers exactly the items before that gap. `left-item` raises at index 0;
`right-item` raises at index `count`. `next!` and `prev!` return `#t` and move one
gap when possible, otherwise return `#f` without moving. Index seek accepts the
same closed range and raises on any other index.

`compare-prefix` receives the complete summary at a candidate physical gap and
returns:

- `'before` when that prefix is before the target;
- `'at` when it denotes the target exactly;
- `'after` when it is after the target.

For one target, results over successive prefixes must be zero or more
`'before`, then zero or more `'at`, then zero or more `'after`. Seek returns the
exact gap when one exists; `'left` chooses the earliest equal gap and `'right`
the latest, which defines repeated-prefix behavior for zero-extent items. When
the target lies inside an item, seek returns the gap immediately before that
item; both biases agree. A target outside the total extent raises. Forward seek
requires the selected gap to be at or after the cursor's current index and
raises otherwise. Seeking by one summary field still returns every accumulated
field in the prefix summary.

A splice range is the half-open item range `[start,end)`. An adapter that
addresses positions inside an item—Tuna text, for example—seeks the containing
item, splits that bounded item itself, and supplies item-boundary replacements.
This keeps item splitting and validation out of the generic collection.

`sum-tree-splice*` interprets every range against the one input tree. The list
must obey this total order:

1. starts are nondecreasing;
2. a zero-width insertion at `p` may repeat and is emitted in input order;
3. zero-width insertions at `p` precede at most one nonempty edit beginning at
   `p`;
4. a nonempty edit `[p,q)` rejects every later start `< q`;
5. an insertion at `q` occurs after the `[p,q)` replacement.

Adjacent nonempty ranges are valid. The implementation validates the complete
edit list and every replacement spec before publishing a result. Sorting,
merging selections, deduplicating cursors, and product conflict behavior happen
above this seam.

### Measure laws

For zero `z`, summaries `a`, `b`, and `c`, item `x`, and sequence concatenation:

```text
combine(z, a) = a = combine(a, z)
combine(combine(a, b), c) = combine(a, combine(b, c))
summary(xs ++ ys) = combine(summary(xs), summary(ys))
summary([x]) = summarize(x)
```

Combination is ordered and need not be commutative. `summary?` must accept the
zero, every item summary, and every combine result. `combine` must not mutate
an operand, return mutable cached state, inspect time or ambient editor state,
or retain a builder. Items, summaries, the descriptor, and all reachable data
that affect summaries must remain observationally immutable.

The package validates result shapes and root/spec identity, but Racket contracts
cannot prove associativity, purity, deep immutability, or seek monotonicity.
Persistence and summary correctness are therefore conditional on these explicit
client laws. Violating them is a client error; it must not be described as a
container guarantee. Deterministic law tests use `equal?`, random
parenthesizations, empty/full ranges, noncommutative summaries, and callback
exceptions for every adapter.

Do not wrap the measure procedures in higher-order contracts on the hot path.
Call them directly from one opaque descriptor and benchmark callback overhead
against an otherwise identical hard-coded text summary implementation.

### Internal representation

Use an immutable wide B+ tree:

- leaves contain bounded vectors of items and cached aggregate information;
- internal nodes contain bounded vectors of children and cached child/total
  summaries;
- for a private maximum capacity `B`, every non-root leaf holds between
  `ceiling(B/2)` and `B` items and every non-root internal node holds between
  `ceiling(B/2)` and `B` children;
- an empty tree is one empty root leaf; a nonempty root leaf may be below the
  minimum, and an internal root has 2 through `B` children;
- all leaves have equal depth;
- bulk construction distributes the final level rather than leaving an
  underfull final sibling;
- deletion redistributes or merges underfull siblings and repeated edits do not
  leave an unbounded population of sparse leaves;
- the root is normalized after split/join;
- packed bulk construction is linear in item count;
- an edit allocates changed boundary leaves and ancestor paths while reusing
  untouched immutable subtrees;
- a private linear builder may use mutable vectors until freeze, but no mutable
  builder-owned node/vector is reachable from any published root;
- cursors retain a root-local path and accumulated prefix summary;
- a batch walks the old root forward once and appends untouched subtrees where
  possible.

Start with safe Racket operations. Introduce `racket/unsafe/ops` only for a
profiled private loop with explicit bounds and ownership tests. Instrument tree
height, node/leaf occupancy, fragmentation/slack, bytes copied, and shared-node
retention before choosing compaction thresholds. Fanout, leaf capacity,
per-item summary caching, chunk policy, and compaction policy are
benchmark-tuned private constants; Ropey's 1024-byte Rust node target is not a
Racket default.

### Cost contract

Let `L` be tree items, `H` balanced height, `K` visited items, `E` edits,
`R` replacement items, and `F` changed boundary/rebalance nodes. Assuming
constant-cost summary operations:

| Operation | Contract/target |
| --- | --- |
| retain a root | `O(1)` |
| total summary/count | `O(1)` |
| packed construction | `O(L)` |
| seek/create cursor | `O(H)` |
| ordered cursor traversal | `O(H + K)` |
| range summary | `O(H)` plus boundary work |
| single splice | `O(H + R)` plus bounded boundary/rebalance work |
| normalized batch splice | target `O((E + 1)H + F + R)` structural work; no scan of untouched items |
| sequence iteration | `O(L)` |

The batch target requires subtree skipping and reuse: sparse edits may visit
search/frontier nodes but must not walk items in untouched spans. Private test
instrumentation records node/item visits and allocations for adversarial sparse
batches. Do not publish a tighter bound until implementation evidence supports
it. Complexity includes callback cost, replacement construction, allocation,
and produced output. Bounded maximum fanout is insufficient by itself; minimum
occupancy is part of the invariant.

## Tuna text interface

Add `tuna/api/text.rkt` as the public pure text facade and keep its SumTree
adapter under `tuna/api/private/`. The public value records are immutable and
transparent; `text?` and its storage remain opaque.

```racket
text?
string->text                         ; string? -> text?
text->string                         ; text? -> string?

text-byte-length                     ; text? -> exact-nonnegative-integer?
text-char-length                     ; text? -> exact-nonnegative-integer?
text-utf-16-length                   ; text? -> exact-nonnegative-integer?
text-line-count                      ; text? -> positive-exact-integer?

text-valid-byte-offset?              ; text? integer? -> boolean?
text-slice                           ; text? byte-start byte-end -> text?
text-insert                          ; text? byte-offset text? -> text?
text-delete                          ; text? byte-start byte-end -> text?
text-replace                         ; text? byte-start byte-end text? -> text?
text-replace*                        ; text? (listof text-edit?)
                                     ; -> (values text? text-change-set?)

(struct text-edit (start end replacement) #:transparent)
(struct text-change (old-start old-end new-start new-end) #:transparent)
(struct text-change-set
  (before-byte-length after-byte-length changes)
  #:transparent)
text-change-set-map-offset           ; change-set old-offset bias -> new-offset

(struct position (line column) #:transparent)

text-byte->char                      ; text byte-offset -> char-offset
text-char->byte                      ; text char-offset -> byte-offset
text-byte->utf-16                    ; text byte-offset -> UTF-16-offset
text-utf-16->byte                    ; text UTF-16-offset -> byte-offset
text-byte->line                      ; text byte-offset -> line-index
text-byte->position                  ; text byte-offset -> position
text-position->byte                  ; text position -> byte-offset
text-line-start-byte                 ; text line-index -> byte-offset
text-line-start-char                 ; text line-index -> char-offset
```

Every coordinate argument is an exact nonnegative integer. Byte, character, and
UTF-16 offsets accept the closed boundary range from zero through their total
length. A line index accepts `[0,text-line-count)`. `text-valid-byte-offset?`
accepts any exact integer and returns `#f` rather than raising; all other invalid
coordinates/ranges raise `exn:fail:contract?`. `text-change-set-map-offset`
accepts an old byte boundary in the change set's closed before-length range and
`(or/c 'before 'after)`, and returns a new byte boundary.

Semantics:

- Byte offsets are zero-based UTF-8 boundaries in `[0, byte-length]`.
- Character coordinates count Unicode scalar values/Racket characters, not
  grapheme clusters.
- Global UTF-16 coordinates count code units from the beginning of the text.
- `position` is a zero-based line and UTF-16 code-unit column.
- U+000A is the only line separator. U+000D, NEL, line separator, and paragraph
  separator remain ordinary content; the text layer does not normalize line
  endings.
- Empty text has one line.
- Positions inside a UTF-8 scalar, inside a UTF-16 surrogate pair, or beyond a
  line fail with an accurate structured argument error; conversion never rounds.
- `text-slice` returns another persistent text value.
- Single edits delegate to `text-replace*` and discard its change set.
- A `text-edit` replacement is a `text?`. Its half-open byte range is interpreted
  in the one old text value.
- `text-replace*` accepts a finite proper list and uses the same ordering rules
  as generic batch splice: equal-position insertions retain list order and
  precede a nonempty replacement beginning there; an insertion at a consumed
  range's end follows that replacement; starts inside a consumed range fail.
- Validation removes only edits with an empty range and empty replacement. An
  empty normalized list returns the input text by identity and an empty change
  set. Replacing bytes with byte-identical content is still a change.

The change set retains one `text-change` per normalized input edit, without
coalescing. To construct it, start `delta` at zero and process edits in normalized
order:

```text
new-start = old-start + delta
new-end   = new-start + replacement-byte-length
delta     = delta + replacement-byte-length - (old-end - old-start)
```

This makes equal-position insertions consecutive in input order while preserving
untouched gaps between separated edits. Offset mapping is defined against the
whole batch:

- strictly inside consumed old text, `'before` maps to that replacement's
  `new-start` and `'after` to its `new-end`;
- at old boundary `x`, `'before` maps after output for a nonempty edit ending at
  `x`, but before zero-width insertions and a nonempty edit beginning at `x`;
- at old boundary `x`, `'after` maps after all zero-width insertions and after
  output for a nonempty edit beginning at `x`;
- elsewhere, add the cumulative delta of edits entirely before the boundary.

Thus at adjacent edits `[p,q)` and `[q,r)`, `'before` at `q` maps to the end of
the first replacement while `'after` maps to the end of the second replacement;
insertions at `q` sit between them. This contract is the foundation for later
markers and overlay endpoints. An originating caret can instead select the
specific `new-end` of its own edit.

Use immutable UTF-8 byte chunks as the initial leaf item. For private chunk
limit `C`:

- chunks are nonempty and end on scalar boundaries;
- each chunk is at most `C` bytes;
- normalization coalesces adjacent chunks whose combined bytes fit in `C`;
- an edit scans/copies only touched bounded chunks;
- chunk-slot slack and unused byte capacity are measured separately.

A piece-descriptor experiment is valid only when each piece has a bounded local
coordinate index or bounded logical length; one multi-megabyte unindexed piece
would invalidate logarithmic coordinate seeking.

The text summary contains only demonstrated coordinate facts:

- byte length;
- character count;
- UTF-16 code-unit count;
- U+000A count;
- trailing-line byte, character, and UTF-16 extents.

Summary and conversion tests must be invariant under every legal repartitioning
of the same UTF-8 bytes. Do not add syntax, face, overlay, marker, longest-line,
display-row, or parser state to the text summary. Those facts have different
invalidation rules.

## Tuna buffer interface and state

The target editor state stores ID-keyed buffers and views:

```racket
(struct editor-state
  (next-buffer-id buffers
                  next-view-id views
                  next-session-id sessions
                  next-frame-id
                  next-layout-tree-id
                  next-layout-item-id))

(struct buffer (id text revision file))
(struct view (id buffer-id))
```

Public operations and queries follow Tuna's existing update/query seam. They do
not expose the private `buffer` state struct.

```racket
(create-buffer #:text [text (string->text "")]
               #:file [file #f])
; text? (or/c path-string? #f) -> positive-exact-integer?

(struct buffer-snapshot (text revision) #:transparent)
(get-buffer-snapshot buffer-id)       ; -> buffer-snapshot?
(get-buffer-text buffer-id)           ; -> text?
(get-buffer-revision buffer-id)       ; -> exact-nonnegative-integer?
(get-buffer-file buffer-id)           ; -> (or/c string? #f)

(insert-buffer-text buffer-id offset replacement
                    #:expected-revision [expected #f])
(delete-buffer-text buffer-id start end
                    #:expected-revision [expected #f])
(replace-buffer-text buffer-id start end replacement
                     #:expected-revision [expected #f])
(replace-buffer-text* buffer-id edits
                      #:expected-revision [expected #f])
; each mutation returns the resulting exact-nonnegative revision

(struct exn:fail:stale-buffer-revision exn:fail
  (buffer-id expected actual)
  #:transparent)

(struct buffer-change
  (buffer-id before-revision after-revision change-set)
  #:transparent)
(struct editor-changed (buffer-changes) #:transparent)
```

`create-buffer` normalizes a path with `path->string` before it enters editor
state. A replacement is a `text?`; edits are `text-edit` values. A supplied
expected revision is an exact nonnegative integer. A mismatch raises
`exn:fail:stale-buffer-revision` before any candidate change, snapshot request,
or event. Expected revision validation still occurs for a no-op.

`get-buffer-snapshot` is the atomic query for background readers: its text root
and revision come from one editor-state snapshot. Separate text/revision queries
remain conveniences and must not be paired when revision identity matters.

Each successful `replace-buffer-text*` invocation validates one base revision,
computes one ordered change set, installs one new text root, increments that
buffer's revision once, and appends one `buffer-change` detail to the current
outer update context. Nested operations remain composable. The outermost editor
update performs the one state commit, persistence snapshot request, and
post-commit `editor-changed` notification. Its `buffer-changes` list preserves
invocation order and can contain several details or buffers; a standalone batch
produces one detail. Interaction-only and non-buffer state changes use an empty
list. Rollback discards both candidate state and accumulated details.

Only an empty normalized edit list is a no-op. It returns the current revision,
returns the exact existing editor-state value from the private transformation,
and contributes no change detail. If the entire outer update preserves state by
identity, it performs no commit, snapshot request, or event. Byte-identical
replacement is not a no-op because later properties, anchors, undo boundaries,
and hooks may still observe the transaction.

The change set is the future common input for view-position transformation,
undo, syntax invalidation, rendering invalidation, diagnostics, and LSP
synchronization. It is Tuna data, not SumTree data.

State-file version 2 encodes logical text and buffer metadata, never SumTree
nodes, fanout, cursors, or cached summaries:

```racket
(tuna-state
  (version 2)
  (state
    (next-ids
      (buffer 2)
      (view 2)
      (session 2)
      (frame 2)
      (layout-tree 2)
      (layout-item 3))
    (buffers
      (buffer 1 0 #f "logical UTF-8 text"))
    (views
      (view 1 1))
    (sessions ...)))
```

The restricted reader settings remain unchanged. Decoding validates the string,
bulk-builds text through `string->text`, validates buffer revision/file fields
and view references, then validates the complete editor state. Deterministic
round trips cover empty/multiline/supplementary text, revisions, and
view-to-buffer references. Whole-text and streaming serialization costs remain
in the large-file benchmark.

## Where surrounding buffer data lives

| Concern | Owner | Representation direction |
| --- | --- | --- |
| canonical characters | Tuna text | SumTree of UTF-8 chunks/pieces |
| byte/character/UTF-16/line facts | Tuna text | cached text summaries |
| text properties copied with text | buffer text metadata | non-overlapping measured run sequence |
| marker/anchor identity and bias | buffer | anchor store transformed by change sets |
| process mark | buffer | durable anchor, independent of views |
| buffer overlays/diagnostics/widgets | buffer annotation layer | dedicated overlap interval index |
| primary point, mark, selections | view | anchors into a buffer revision |
| narrowing/accessibility | view execution context | pair of biased anchors |
| viewport, scroll, folds shown only here | view | view state/derived display map |
| major/minor modes and local values | buffer | buffer configuration generation |
| syntax table/language configuration | buffer | mode-owned configuration generation |
| syntax parse state and fontification | derived runtime cache | keyed by text/property/mode/parser generations |
| undo/redo grouping | buffer | transaction history referencing roots/change sets |
| file identity/fingerprint/save point | buffer | file-backing record |
| rendering layout cache | renderer/view | invalidatable revision-keyed cache |

A non-overlapping run map is the second concrete measured-sequence use case. A
test-only adapter in `sum-tree-test/` validates the generic algebra and seek
seam without adding text properties to the editable-buffer milestone. It proves
that the collection is not merely a rope with generic names.

An arbitrary-overlap interval index is not part of the initial SumTree surface.
Implement it with the marker/overlay milestone, when endpoint transformation,
priority, evaporation, and query semantics are known. It may reuse private wide
balanced-tree techniques, but its interface is an interval index, not a
sequence.

The foundation nevertheless fixes the semantics that later structures consume:

- an anchor has buffer identity, current revision, byte offset, `'before` or
  `'after` affinity, and attached/detached state;
- local anchors are transformed eagerly on each committed change set; deleting
  their covered text maps them with the same before/start or after/end rule as
  `text-change-set-map-offset`; buffer death detaches them;
- the anchor store, not a SumTree cursor or node identity, provides durable
  identity and lookup;
- overlay endpoints are anchors; the interval index is a derived query index
  updated atomically with those anchors, never a second source of coordinates;
- text-property runs eventually commit atomically with text, carry explicit
  front/rear insertion stickiness, coalesce equal adjacent payloads, and copy
  only through property-aware copy operations;
- property-only, overlay-only, and mode/configuration changes use their own
  generations/events rather than pretending to be byte edits.

Stage 4 uses private fixtures for these transformations before the change-set
contract is accepted. It does not add the later public marker, overlay, or
property interfaces.

## Use-case walkthroughs

### Local typing

A view resolves its cursor in buffer revision `r`. Tuna submits one insertion,
the text adapter replaces at most bounded boundary chunks and path-copies one
root path, the buffer installs revision `r+1`, and the view cursor advances by
the emitted change set. A private counter verifies that copied text bytes are
bounded by replacement bytes plus touched chunk capacity rather than document
size. The gap-buffer control is expected to be faster in this best case;
acceptance depends on measured latency and allocation, not winning every
workload.

### Two hundred cursors

The command resolves all selections against revision `r`, sorts them, applies
Tuna's duplicate/overlap policy, and sends one disjoint edit list. The text
adapter seeks forward through old chunks, creates one replacement root, emits
one change set, and records one eventual undo unit. Syntax, fontification,
layout, and LSP receive one coalesced invalidation pass. No edit observes the
result of an earlier cursor edit.

### Replace-all while a parser reads

The parser obtains one atomic `buffer-snapshot`, retaining its text root and
revision `r` without copying. Replace-all submits expected revision `r` and
either commits all ranges or reports staleness. Parser output is published only
for its source revision or explicitly mapped through a known change set. The old
text root remains valid until the parser releases it.

### Text properties and copy/paste

Property runs are aligned with text extents and receive the same normalized
change set. Insertion inheritance and copy policy belong to the property-run
adapter. Copying text may copy selected properties; overlays never participate.
The canonical text summary remains unchanged by property vocabulary.

### Dense overlapping diagnostics

Diagnostics use biased anchors plus a per-buffer interval index. A viewport
query reports `O(log A + K)` as an interval-index target for `A` annotations and
`K` results. The text SumTree is not scanned and does not cache diagnostic sets
in every ancestor.

### Syntax highlighting

An edit invalidates syntax from the earliest language-dependent restart point.
A background parser/fontifier consumes an immutable text snapshot and produces
property/decorations ranges keyed by text revision, syntax-affecting property
generation, buffer mode/configuration generation, and parser/fontifier version.
Visible ranges are prioritized. Derived `fontified` state is not persisted as
canonical buffer content.

### Two views of one buffer

Both views share text, revision, modes, undo, process marks, and buffer-scoped
annotations. They have independent primary point, mark, selections, accessible
ranges, viewport, and scroll. Every interactive command names its view context;
a command against an undisplayed buffer supplies explicit positions/ranges and
uses no hidden point. An edit from either view transforms both views' anchors
through the same change set. This covers the common useful part of Emacs
indirect-buffer usage without introducing a second document identity in this
milestone.

### Undo

A multicursor command contributes one buffer transaction containing old/new
text and property roots, its forward/inverse change maps, and metadata changes.
Undo and redo later pass through the same validation, anchor transformation,
generation, persistence, and notification pipeline as an ordinary edit; they do
not silently swap a root. Persistent roots make retention cheap in operation
count, not free in memory; history must be bounded and retained-root memory
benchmarked. Undo ownership is an explicit Tuna buffer decision, not inferred
from Emacs indirect buffers.

### Terminal and generated buffers

A terminal backend owns cursor-addressed terminal state, alternate screens,
ANSI state, and scrollback; it publishes batched text projections into a Tuna
buffer. Generated Git/status content likewise regenerates a buffer through
ordinary batch edits. Read-only regions, trusted producer authorization,
process marks, and generated annotations are Tuna policies above text storage.
Future workloads cover append, line replacement/clearing, alternate-screen
replacement, and scrollback trimming without changing `sum-tree`.

## Validation and benchmark gate

### Correctness

Use a simple list/vector reference SumTree and an immutable-string reference
text model.

Required generated/differential coverage:

- empty, singleton, shallow, deep, split, merge, and root-collapse shapes;
- every cursor boundary and both biases, including empty/end cursors and runs
  of 1, 2, and many repeated zero extents;
- all insertion/nonempty-edit shared-endpoint combinations and multiple
  equal-position insertions;
- random build, seek, noncommutative range-summary, single-splice, and
  batch-splice sequences;
- retained old roots and cursors after later splits, merges, and root collapse;
- client callback exceptions during build and splice, with all old roots intact;
- invalid root/spec combinations, reversed ranges, unordered edits, duplicate
  nonempty ranges, overlap, and stable input order for equal-position inserts;
- summary-law checks for counted values, a non-text weighted timeline, text, and
  non-overlapping property runs;
- ASCII, multibyte UTF-8, supplementary Unicode, combining characters, U+000A,
  lone U+000D, CRLF, NEL, line/paragraph separators, empty lines, trailing
  newline, and very long lines; only U+000A changes Tuna's logical line count;
- rejection—not Ropey-style rounding—of byte offsets inside UTF-8 scalars and
  UTF-16 columns inside surrogate pairs;
- byte/character/global-UTF-16/line-position round trips at every valid
  boundary;
- identical summaries/conversions under varied legal UTF-8 chunk partitions;
- batch text edits compared with a descending application to the flat oracle;
- anchor mapping for insertion, deletion, replacement, adjacency, equal-position
  insertion order, and before/after affinity;
- test-only property runs for front/rear stickiness, split/coalesce, empty text,
  and property-bearing copy;
- deterministic version-2 serialization and state round trips.

Private invariant checks verify occupancy, equal leaf depth, child counts,
cached totals, ordered contents, and absence of mutable published storage. Do
not export node inspection merely for tests.

### Performance

Run on the supported Racket CS runtime and report Racket version, machine,
seed, warmup, median/p95/p99 wall time, CPU time, cumulative allocation, live
memory after major GC, peak memory, and GC time.

Workloads:

1. Build, scan, slice, and serialize 1, 10, and 100 MiB texts.
2. Ten thousand local insert/backspace operations at one cursor.
3. Batches of 10, 100, 1,000, and 10,000 distributed cursors.
4. Adversarial edits alternating document ends.
5. Large paste/delete and 1,000–100,000 replace-all ranges.
6. Random byte/character/line/UTF-16 conversions.
7. A multi-megabyte single line and millions of short lines.
8. Retain 1,000 and 10,000 roots while editing and scanning old roots; measure
   roots alone, retained slices, and cursors separately.
9. Random edits until sparse-leaf/slack ratios stabilize or degrade, followed by
   redistribution/compaction and full scans.
10. Property-run seek/split/coalesce workloads.
11. Annotation overlap workloads for the later interval-index decision.

Controls use identical fixed seeds, edit traces, corpus hashes, validation
policy, process isolation, warmup, GC schedule, and snapshot population:

- flat immutable UTF-8 bytes/string, retaining equivalent old snapshots;
- a small mutable gap buffer for localized editing, with snapshot-copy cost
  reported separately whenever snapshots are retained;
- chunk items versus bounded/indexed immutable piece descriptors;
- the generic measure descriptor versus an otherwise identical hard-coded text
  summary path with the same layout, chunks, algorithms, inputs, and optimization
  barriers, run in fresh processes;
- a measured finger-tree implementation only if an available implementation's
  license and semantics are acceptable.

Ropey may inform workload design and implementation review, but a loop of
Ropey single edits is not a semantic batch-edit control: its later operations
observe earlier mutations, whereas Tuna's batch coordinates all refer to one
old snapshot.

Acceptance requires:

- no correctness disagreement with the references;
- `O(1)` root retention and observable old-root immutability;
- local-edit copied bytes bounded by replacement bytes plus touched chunk
  capacities, independent of document size;
- sparse-batch instrumentation showing no item/leaf visits in untouched spans
  and structural visits bounded by the declared `E`, `H`, and `F` model;
- logarithmic node-visit growth for coordinate seeks;
- B+ occupancy invariants and the chunk invariant that no adjacent chunks fit
  within one `C`-byte chunk after normalization;
- separate reports for node-slot slack, chunk-byte slack, and memory retained by
  roots, slices, and cursors;
- measured generic-callback cost, local-typing cost relative to the gap control,
  scattered-edit behavior, and retained-snapshot behavior;
- selected fanout, leaf/chunk sizes, and compaction thresholds recorded with the
  benchmark corpus, seed, machine, runtime, samples, and confidence statistics;
- explicit owner approval of the benchmark report before Stage 3. No arbitrary
  cross-machine latency ratio is declared in advance.

Timing thresholds do not run in ordinary CI. Correctness and structural
instrumentation do.

## Implementation stages

### Stage 1: standalone SumTree seam

Add:

```text
sum-tree/
  main.rkt
  private/node.rkt
  private/build.rkt
  private/cursor.rkt
  private/splice.rkt
  private/instrument.rkt

sum-tree-test/
  info.rkt
  sum-tree/public.rkt
  sum-tree/randomized.rkt
  sum-tree/run-map.rkt

sum-tree-bench/
  sum-tree/run.rkt
  sum-tree/workloads.rkt
```

The root `info.rkt` remains the package manifest and adds `sum-tree` to
`setup-collects`; a nested `sum-tree/info.rkt` is unnecessary without
collection-specific metadata. The root `Makefile` discovers `sum-tree/`,
`sum-tree-test/`, and `sum-tree-bench/` for format/review/resyntax, runs both
test trees, and adds a non-CI benchmark target.

Deliver the exact spec/edit/cursor contracts above, persistent construction,
index and prefix-summary seek, range summaries, normalized batch splice,
private instrumentation/invariant checks, list oracle, weighted non-text
fixture, and test-only property-run fixture.

Stage-1 gate:

- every public signature and failure mode is tested at the module seam;
- randomized differential and private invariant suites pass;
- callback exceptions preserve all old roots;
- sparse batches skip untouched subtrees under instrumentation;
- a fresh reviewer approves the generic seam before Tuna text depends on it.

### Stage 2: Tuna text adapter

Add:

```text
tuna/api/text.rkt
tuna/api/private/text.rkt
tuna-test/tuna/api/text.rkt
sum-tree-bench/sum-tree/text-workloads.rkt
docs/research/sum-tree-benchmark.md
```

Deliver the opaque text facade, bounded UTF-8 chunks, coordinate summaries,
strict conversion semantics, persistent slices, single edits, simultaneous
batch edits, ordered change sets, string oracle, Unicode/chunk-partition
differential tests, anchor/property fixtures, and reproducible text benchmarks.

Stage-2 gate:

- all coordinate/edit/change-map reference tests pass;
- generic and hard-coded-summary variants use identical internals and produce a
  reviewed callback-cost report;
- selected `B`, `C`, and compaction constants plus raw workload metadata are
  recorded in `docs/research/sum-tree-benchmark.md`;
- the repository owner explicitly approves that report before buffer
  integration.

### Stage 3: Tuna buffers

Install the target state shape completely:

- replace `next-subject-id`/`subjects`/`file-subject` with
  `next-buffer-id`/`buffers`/`buffer`;
- replace `view-subject-id` with `view-buffer-id` and validate every reference;
- expose `create-buffer`, buffer text/revision/file queries, and revision-guarded
  edit operations;
- remove subject operations/queries from the public facade;
- validate immutable ID-keyed buffers, matching positive IDs, `text?`, exact
  nonnegative revisions, and normalized string-or-`#f` files;
- add state-file version 2 with the exact logical-text shape above and retain
  the restricted reader;
- suppress commit/snapshot/event work for an identity candidate state;
- accumulate ordered `buffer-change` details in the outer update and publish one
  aggregate `editor-changed` event only after commit;
- update `docs/architecture.org` and roadmap terminology to use buffers and
  view-to-buffer references; Stage 4, not Stage 3, marks the item complete.

Files:

```text
tuna/api/main.rkt
tuna/api/operation.rkt
tuna/api/query.rkt
tuna/api/events.rkt
tuna/api/private/state.rkt
tuna/api/private/persistence.rkt
tuna/api/private/update.rkt
tuna/api/private/events.rkt
tuna-test/tuna/api.rkt
tuna-test/tuna/api/private/state.rkt
tuna-test/tuna/api/private/persistence.rkt
tuna-test/tuna/events.rkt
docs/architecture.org
docs/roadmap.org
info.rkt
Makefile
```

Stage-3 gate:

- one standalone batch produces one revision and one detail inside one outer
  state commit, snapshot request, and aggregate event;
- nested edits preserve detail order while the outer update still commits,
  snapshots, and notifies once;
- stale, rollback, and identity-no-op paths produce no state/snapshot/event side
  effects or leaked change details;
- version-2 persistence rejects malformed text/references and round-trips the
  required Unicode/revision cases deterministically;
- existing layout, command, input, rendering, REPL, and persistence suites pass.

### Stage 4: proof against surrounding-data cases

Before marking the editable-buffer roadmap item complete, private fixtures prove:

- text-property insertion stickiness, split/coalesce, and property-bearing copy
  can consume the ordered change set atomically;
- anchors map correctly through insert/delete/replace, shared endpoints,
  deletion collapse, and equal-position insertion order;
- an overlay endpoint pair has one anchor source of truth and can update a
  derived interval index atomically;
- two independent snapshot readers and two view-anchor sets survive edits;
- a 200-cursor edit is one batch, revision, and event;
- stale expected revision cannot commit and an empty normalized batch cannot
  notify;
- durable anchors and arbitrary-overlap indexes remain separate interfaces.

These are semantic foundation tests, not public marker/overlay/property
features. After they pass and the benchmark report is approved, mark the
editable-buffer roadmap item complete.

### Validation commands

Run from the repository root at every stage:

```console
make format
make resyntax
make review
raco test -j 4 sum-tree-test/
raco test -j 4 tuna-test/
```

The benchmark is explicit and timing-free CI never invokes it:

```console
racket sum-tree-bench/sum-tree/run.rkt \
  --seed 20260714 \
  --output .state/sum-tree-benchmark.json
```

The reviewed summary and selected constants live in
`docs/research/sum-tree-benchmark.md`; raw machine-specific output remains under
`.state/`.

## Non-goals

- CRDTs, collaboration, remote merge, Lamport clocks, or tombstones;
- marker and overlay public interfaces;
- a generic interval-index public module;
- syntax parser or fontification implementation;
- undo/redo commands and history pruning;
- view cursor/selection and leaf-display implementation;
- file visiting, encoding detection, save conflict handling, or autosave;
- grapheme-cluster and visual-column coordinates;
- exposing tree nodes, chunks, summaries, builders, or mutable roots;
- reproducing Emacs text-property or overlay symbol vocabularies;
- copying Zed's exact traits, fanout, chunk sizes, anchors, or CRDT.

## Primary sources

- GNU Emacs Lisp Reference: [Buffers](https://www.gnu.org/software/emacs/manual/html_node/elisp/Buffers.html), [Indirect Buffers](https://www.gnu.org/software/emacs/manual/html_node/elisp/Indirect-Buffers.html), [Markers](https://www.gnu.org/software/emacs/manual/html_node/elisp/Markers.html), [Text Properties](https://www.gnu.org/software/emacs/manual/html_node/elisp/Text-Properties.html), [Overlays](https://www.gnu.org/software/emacs/manual/html_node/elisp/Overlays.html), [Narrowing](https://www.gnu.org/software/emacs/manual/html_node/elisp/Narrowing.html), [Undo](https://www.gnu.org/software/emacs/manual/html_node/elisp/Undo.html), and [Fontification Functions](https://www.gnu.org/software/emacs/manual/html_node/elisp/Fontification-Functions.html).
- GNU Emacs source at `c6147e2b539dc3490b47a924bed86da00cc763a7`: [`buffer.h`](https://github.com/emacs-mirror/emacs/blob/c6147e2b539dc3490b47a924bed86da00cc763a7/src/buffer.h), [`marker.c`](https://github.com/emacs-mirror/emacs/blob/c6147e2b539dc3490b47a924bed86da00cc763a7/src/marker.c), [`intervals.c`](https://github.com/emacs-mirror/emacs/blob/c6147e2b539dc3490b47a924bed86da00cc763a7/src/intervals.c), [`itree.c`](https://github.com/emacs-mirror/emacs/blob/c6147e2b539dc3490b47a924bed86da00cc763a7/src/itree.c), [`syntax.el`](https://github.com/emacs-mirror/emacs/blob/c6147e2b539dc3490b47a924bed86da00cc763a7/lisp/emacs-lisp/syntax.el), and [`jit-lock.el`](https://github.com/emacs-mirror/emacs/blob/c6147e2b539dc3490b47a924bed86da00cc763a7/lisp/jit-lock.el).
- Zed source at `20a3f7705f18a9913571d4fcdee687b76abdb213`: [`sum_tree`](https://github.com/zed-industries/zed/blob/20a3f7705f18a9913571d4fcdee687b76abdb213/crates/sum_tree/src/sum_tree.rs), [`cursor`](https://github.com/zed-industries/zed/blob/20a3f7705f18a9913571d4fcdee687b76abdb213/crates/sum_tree/src/cursor.rs), [`rope`](https://github.com/zed-industries/zed/blob/20a3f7705f18a9913571d4fcdee687b76abdb213/crates/rope/src/rope.rs), and [`text`](https://github.com/zed-industries/zed/blob/20a3f7705f18a9913571d4fcdee687b76abdb213/crates/text/src/text.rs).
- Zed Engineering: [Rope & SumTree](https://zed.dev/blog/zed-decoded-rope-sumtree) and [Text Coordinate Systems](https://zed.dev/blog/zed-decoded-text-coordinate-systems).
- [`zed-sum-tree` 0.2.0 registry metadata](https://crates.io/api/v1/crates/zed-sum-tree) and matching Zed publication source at `e317d98915224105b148c43edd7b788f334e1317`: [`sum_tree.rs`](https://github.com/zed-industries/zed/blob/e317d98915224105b148c43edd7b788f334e1317/crates/sum_tree/src/sum_tree.rs), [`cursor.rs`](https://github.com/zed-industries/zed/blob/e317d98915224105b148c43edd7b788f334e1317/crates/sum_tree/src/cursor.rs), and [`tree_map.rs`](https://github.com/zed-industries/zed/blob/e317d98915224105b148c43edd7b788f334e1317/crates/sum_tree/src/tree_map.rs).
- Ropey 1.6.1 at `d41ee247f2f097c7f9c8e4730b7dd884734f1ee5`: [design](https://github.com/cessen/ropey/blob/d41ee247f2f097c7f9c8e4730b7dd884734f1ee5/design/design.md), [`rope.rs`](https://github.com/cessen/ropey/blob/d41ee247f2f097c7f9c8e4730b7dd884734f1ee5/src/rope.rs), [`node.rs`](https://github.com/cessen/ropey/blob/d41ee247f2f097c7f9c8e4730b7dd884734f1ee5/src/tree/node.rs), and [`slice.rs`](https://github.com/cessen/ropey/blob/d41ee247f2f097c7f9c8e4730b7dd884734f1ee5/src/slice.rs).
- Boehm, Atkinson, and Plass, [Ropes: an Alternative to Strings](https://www.cs.tufts.edu/comp/150FP/archive/hans-boehm/ropes.pdf).
- Hinze and Paterson, [Finger trees: a simple general-purpose data structure](https://www.cs.ox.ac.uk/ralf.hinze/publications/FingerTrees.pdf).
- Crowley, [Data Structures for Text Sequences](https://www.cs.unm.edu/~crowley/papers/sds.html).
- VS Code, [Text Buffer Reimplementation](https://code.visualstudio.com/blogs/2018/03/23/text-buffer-reimplementation).
- Racket Reference: [Vectors](https://docs.racket-lang.org/reference/vectors.html), [Byte Strings](https://docs.racket-lang.org/reference/bytestrings.html), [Sequences](https://docs.racket-lang.org/reference/sequences.html), [Unsafe Operations](https://docs.racket-lang.org/reference/unsafe.html), and [Garbage Collection](https://docs.racket-lang.org/reference/garbagecollection.html).
