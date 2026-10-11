# Persistent text storage

## Question

What representation should back Tuna's future opaque, pure text API?

## Tuna constraints

Tuna text values must support insertion, deletion, replacement, slicing, and
conversion among UTF-8 byte offsets, characters, and UTF-16 line/column
positions. Edits return new text values while leaving old values usable as
snapshots; see [the text-model note](../notes/text-model-note.md).

The representation is private. The public buffer and text APIs must not expose
its tree, chunks, or storage strategy.

## Findings

### Persistent snapshots matter

A mutable gap buffer makes nearby inserts cheap, but a snapshot requires copying
or a separate persistence layer. Tuna's immutable editor-state model makes
structural sharing a better default: a prior text root can remain available to
undo, rendering, parsing, or other readers while a later edit creates a new
root.

This does not choose a specific structure. It does rule out making an
in-place-only representation the default without first designing its snapshot
story.

### Coordinate summaries belong with the text

A side index can answer line and coordinate queries, but rebuilding it after
edits recreates the whole-buffer work that a non-flat representation is meant
to avoid. A tree whose nodes summarize their subtrees can maintain:

- UTF-8 byte length;
- character count;
- UTF-16 code-unit count;
- newline count; and
- enough first/last-line information to convert byte offsets and line/column
  positions.

That allows navigation and locating a visible range to follow tree descents
rather than rescan a document. Producing a range still traverses its covered
text. Summary contents and exact complexity claims are implementation details
to validate with benchmarks.

### The viable candidates are a summary rope and a piece tree

An augmented persistent rope is the leading hypothesis. Immutable leaf chunks
and a balanced tree naturally provide structural sharing; per-node summaries
also make the required coordinate conversions a first-class operation.

A piece tree is a credible alternative, especially for large mostly-read-only
files: it keeps original bytes separate from an append-only edit buffer and
orders descriptors in a balanced tree. If Tuna needs character and UTF-16
conversions, it must carry equivalent summary metadata. Long editing sessions
also need a fragmentation strategy.

A gap buffer remains worth benchmarking as a local-edit baseline, but is not an
assumed fit for Tuna's snapshot-oriented model. A whole immutable string is a
useful reference implementation and differential-test oracle, not the intended
large-file implementation.

## Coordinate boundary

Use UTF-8 byte offsets privately, with 0-based line and UTF-16 column positions
at browser/LSP boundaries. Decide public character-facing positions with the
buffer, marker, and extension APIs.

## Decision procedure

Choose a representation only after a Racket CS benchmark and correctness gate.
The benchmark should cover at least 1, 10, and 100 MiB inputs and compare:

- opening and serializing text;
- localized typing and deletion;
- scattered edits and a large paste;
- byte, character, line, and UTF-16 conversions;
- visible-range slicing;
- a very long line; and
- retaining and reading prior roots after edits.

Keep a simple reference implementation for randomized differential tests. Each
operation and conversion must agree with the candidate implementation across
Unicode and newline edge cases before performance results guide a choice.

## Sources

- [Zed: Rope & SumTree](https://zed.dev/blog/zed-decoded-rope-sumtree)
- [Zed: Rope Optimizations, Part 1](https://zed.dev/blog/zed-decoded-rope-optimizations-part-1)
- [VS Code: Text Buffer Reimplementation](https://code.visualstudio.com/blogs/2018/03/23/text-buffer-reimplementation)
- [Boehm, Atkinson, and Plass: Ropes: an Alternative to Strings](https://www.cs.tufts.edu/comp/150FP/archive/hans-boehm/ropes.pdf)
- [Crowley: Data Structures for Text Sequences](https://www.cs.unm.edu/~crowley/papers/sds.pdf)
- [Racket `treelist`](https://docs.racket-lang.org/reference/treelist.html)
- [Tree-sitter advanced parsing](https://tree-sitter.github.io/tree-sitter/using-parsers#advanced-parsing)
