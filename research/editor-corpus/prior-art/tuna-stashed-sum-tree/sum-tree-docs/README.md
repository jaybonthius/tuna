# SumTree

`sum-tree` is an immutable, persistent measured sequence. A descriptor supplies:

- a zero summary and a predicate for summary values;
- a function that maps each item to a summary; and
- an associative, order-preserving function that combines summaries.

The private tree nodes cache their item counts and combined summaries. Construction and transformations return roots rather than modifying existing ones, so retained roots and cursors over those roots remain valid. Topology, node capacity, and balancing machinery are not public API.

## Working with a tree

Build a descriptor with `make-sum-tree-spec`, then create an empty tree or build from a list or vector. Iteration exposes the items in order. Whole-tree and range summaries reuse cached measurements; a range summary measures a slice without requiring clients to know the tree shape.

A cursor is mutable navigation state bound to the root passed to `sum-tree-cursor`. It sits at a gap between items and reports its item index, adjacent items, and the complete summary of the prefix to its left. It can move one item, jump to an item index, or seek by applying a client comparator to prefix summaries. Measured seek uses cached summaries to guide navigation; left and right bias resolve a target that lies on a summary boundary. Moving a cursor never changes its root, and a cursor is not an anchor that follows edits.

`sum-tree-splice` replaces one item-index range and returns a new root. `sum-tree-splice*` takes a normalized batch of `sum-tree-edit` values: ranges are nondecreasing and non-overlapping, replacements use the same descriptor, and every range addresses the old root. Empty ranges at the same point are allowed. The batch result does not make later coordinates observe earlier replacements.

## Public surface

The package exports 31 names in three groups:

- **Descriptors, construction, and inspection:** `sum-tree-spec?`, `make-sum-tree-spec`, `sum-tree?`, `sum-tree-empty`, `list->sum-tree`, `vector->sum-tree`, `sum-tree-empty?`, `sum-tree-count`, `sum-tree-summary`, `sum-tree-range-summary`, and `in-sum-tree`.
- **Root-bound cursors:** `sum-tree-cursor?`, `sum-tree-cursor`, `sum-tree-cursor-seek-index!`, `sum-tree-cursor-seek!`, `sum-tree-cursor-seek-forward!`, `sum-tree-cursor-next!`, `sum-tree-cursor-prev!`, `sum-tree-cursor-index`, `sum-tree-cursor-prefix-summary`, `sum-tree-cursor-at-start?`, `sum-tree-cursor-at-end?`, `sum-tree-cursor-left-item`, and `sum-tree-cursor-right-item`.
- **Persistent edits:** `sum-tree-edit`, `sum-tree-edit?`, `sum-tree-edit-start`, `sum-tree-edit-end`, `sum-tree-edit-replacement`, `sum-tree-splice`, and `sum-tree-splice*`.

Cached summaries make measured navigation and local rebuilding practical without flattening the sequence. Actual cost depends on item summaries, tree shape, edit distribution, retained roots, and runtime; the package does not promise a universal complexity or latency bound.

## Clients

Tuna's UTF-8 text layer is a client, not part of generic `sum-tree`. It chooses text items and summaries for byte, character, UTF-16, and line coordinates, then adds text-specific slices, edits, revisions, and change sets.

See [performance and comparison notes](performance.md), the Tuna [buffer/text API guide](../docs/guide/api.md), and Tuna's [buffer ownership decision](../docs/adr/0002-persistent-text-buffers.md).
