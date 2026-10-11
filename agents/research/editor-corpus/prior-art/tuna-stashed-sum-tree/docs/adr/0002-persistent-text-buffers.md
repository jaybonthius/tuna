# Persistent text buffers

## Status

Implemented.

## Terms

- **Buffer**: the shared editable context. It owns opaque persistent text, one revision stream, and an optional file association.
- **View**: an identity that refers directly to one buffer. Multiple views of a buffer observe the same text and revisions.

## Settled decisions

- A buffer owns shared text and buffer-scoped editing state. A view does not own or copy text.
- Tuna keeps the text representation private. Its persistent measured SumTree adapter preserves old snapshots, caches coordinate summaries, and applies simultaneous batches whose coordinates all name the old snapshot. Tree nodes and text chunks are not public API.
- Text edits use UTF-8 byte coordinates at scalar boundaries. Revisions provide optimistic conflict detection. Each committed batch advances the revision once and produces one change set in one editor-change event.

## Alternatives

- Flat strings and gap buffers are simpler, and a gap buffer can be much faster for nearby mutable edits. They do not meet the retained-snapshot and scattered old-snapshot batch requirements without copying or additional machinery.
- A separate document or shared-text identity could fan edits out to multiple editing contexts. Tuna has no current need for that split, so its extra identity, lifetime, revision, notification, and persistence rules are not justified.

## Consequences

View cursor and selection state, undo, file visiting and saving, markers, and overlays remain separate roadmap work. `#:file` records an association; it does not visit or save a file.

See the [Tuna buffer/text API guide](../guide/api.md) and the generic [SumTree overview](../../sum-tree-docs/README.md).
