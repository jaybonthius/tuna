# Text model note

Tuna's editable text store is the opaque mutable UTF-8 gap buffer in
`tuna/api/private/buffer-content.rkt`. It owns logical bytes and a separate LF
line index. Physical gap coordinates never cross the private module boundary.

Buffer IDs identify live text through a runtime-owned lazy map. The editor lock
guards every access. Mutable text is not part of immutable `editor-state` or its
state file; a restored buffer starts with empty text. Successful outer updates
discard their private cancellation journal, so it does not become undo history.

Public text operations use Racket strings. The adapter copies input to immutable
UTF-8 bytes and returns immutable strings. All internal edit and range positions
are exact logical UTF-8 byte offsets. Computed locations use zero-based lines and
UTF-16 columns.

The basic public surface covers initial text, full/range reads, byte length,
location conversion, insertion, deletion, and replacement. Private batch change
sets and cancellation handles are not public values.

Each view owns one exact UTF-8-boundary point. Buffer edits map every view of the
buffer in the same outer update. Mapping is left-biased: point at an insertion
stays before it, point inside removed text collapses to the start, and point at
or after the removed end shifts by the replacement delta. Point resets to zero
when metadata is restored because live text is not persisted.

See the [gap-buffer plan](../plans/gap-buffer-plan.md),
[editable-buffer API plan](../plans/editable-buffer-api-plan.md), and
[ADR 0002](../adr/0002-runtime-owned-subject-text.md). The plans retain the
subject-era names used when they were executed.

Deferred features remain separate:

- file visiting, saving, and dirty state
- undo and redo
- mark, markers, and selections
- text properties and overlays
- viewport state, cursor rendering, and measured rows
- parser, fontification, and other derived caches
