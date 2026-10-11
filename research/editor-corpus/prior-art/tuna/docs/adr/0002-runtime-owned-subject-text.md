# Runtime-owned buffer content

## Status

Accepted. Terminology updated by TUNA-F-0007; the file path is retained for
stable historical links.

## Context

Tuna's editor state is an immutable, asynchronously persisted metadata value.
Editable text is a private mutable `buffer-content`. Placing that mutable object
inside `editor-state` would let candidate states and asynchronous state snapshots
share storage that changes in place.

Public editor operations already share one nested update boundary: later calls
read candidate work, and an outer failure publishes neither candidate metadata
nor an event. A completed text edit cannot survive that failure without making
committed metadata and live text disagree.

## Decision

The editor runtime owns a lazy mutable hash from existing buffer IDs to opaque
`buffer-content` values. The existing editor lock guards every lookup, creation,
read, and mutation. Lookup uses candidate state while an update is active and
committed state otherwise.

- A buffer receives empty live text on first access.
- `create-buffer` may initialize that text from a mutable or immutable Racket
  string; Tuna copies its value to private UTF-8 bytes.
- Public reads return immutable strings.
- Positions are exact logical UTF-8 byte boundaries; computed line and UTF-16
  locations use the private buffer's existing semantics.
- Mutable text is not part of `editor-state` or the state file. A buffer restored
  from a state file starts with empty text.
- Successful edits use the existing generic `editor-changed` event.

Lazy creation prepares content before publication. During an update, one
callback-free break-disabled extent registers the created ID before publishing
the runtime-map entry. Cancellation may remove a registered ID even if
publication did not occur.

The active private update context holds a LIFO of preallocated reversal slots and
the IDs registered by lazy creation. Each successful low-level mutation publishes
an opaque one-shot reversal handle into its slot in the mutation's final
callback-free break-disabled extent. An outer update that exits before commit
reverses populated slots newest-first and removes registered entries before
releasing the editor lock.

Reversal checks ownership, one-shot use, and update-journal LIFO order, then uses
prepared inverse splices without coordinate/edit revalidation or capacity
allocation. It does not capture a whole-buffer snapshot.

Cancellation is terminal. A continuation barrier and active-context state reject
attempted continuation re-entry after commit or cancellation.

Before commit, runtime-content validation checks buffer IDs, `buffer-content?`
values, and journal/content object identity. It never snapshots or copies whole
text. Candidate-state publication and the update's committed state then occur in
one callback-free break-disabled commit point. Snapshot requests and the generic
event run afterward. Their raise or break cannot reverse committed metadata or
text.

## Consequences

- Text edits retain gap-buffer locality and allocation behavior.
- Nested commands read their own text changes and preserve Tuna's established
  exception, break, nonlocal-exit, and no-event-on-precommit-failure behavior.
- View points can be mapped in candidate metadata after a reversible edit and
  are discarded together with that candidate if the outer update fails.
- The cancellation journal exists only for one update and is discarded on
  commit. It is neither undo, a public transaction, nor retained history.
- Immutable metadata snapshots remain safe for the existing asynchronous state
  worker without changing its locking model.
- Restarting the editor does not restore unsaved buffer text.
- File loading, saving, dirty tracking, undo, markers, properties, overlays, and
  rendering optimization remain independent work.
- No revision or modification counter is introduced by the basic editable-text
  layer.

The original implementation contract is recorded in
[`editable-buffer-api-plan.md`](../plans/editable-buffer-api-plan.md); its
subject-era names are historical.
