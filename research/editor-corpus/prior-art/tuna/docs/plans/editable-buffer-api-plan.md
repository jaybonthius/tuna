# Editable buffer API plan

## Status

Implemented

## Goal

Give each existing file subject live editable text backed by the private mutable
UTF-8 gap buffer, then expose the smallest public Racket API for reading,
locating, inserting, deleting, and replacing that text.

This plan adds text to the current subject/update model. It does not add file
visiting, editor metadata, rendering, or a second text representation.

## Terms

- **Subject text**: the live `buffer-content` associated with one existing
  `file-subject` ID.
- **Text location**: a computed line and column description of one exact UTF-8
  byte boundary. It is a value, not a durable marker.
- **Reversal handle**: an opaque, one-shot private value containing the prepared
  inverse data for one completed low-level mutation.
- **Update cancellation journal**: the active outer editor update's private LIFO
  of reversal slots and lazily-created subject-content IDs.

The cancellation journal is unavoidable because Tuna already guarantees that
nested public operations read their own candidate state and that an outer update
which fails publishes no partial work. Letting a completed text edit survive
such a failure would make committed metadata and live text disagree. The journal
exists only for the dynamic extent of one update, is discarded on commit, and is
neither undo nor retained transaction history.

## Public contract

### Text location

Add `tuna/api/text.rkt`:

```racket
(struct text-location (line line-byte-start char-column utf16-column)
  #:transparent)

(provide
  (contract-out
    [text-location? (-> any/c boolean?)]
    [text-location-line
     (-> text-location? exact-nonnegative-integer?)]
    [text-location-line-byte-start
     (-> text-location? exact-nonnegative-integer?)]
    [text-location-char-column
     (-> text-location? exact-nonnegative-integer?)]
    [text-location-utf16-column
     (-> text-location? exact-nonnegative-integer?)]))

(module+ private
  (provide text-location))
```

The public module exports only the predicate and four accessors. The private
submodule exports the constructor to `tuna/api/query.rkt`.

Fields mean:

- `line`: zero-based LF-delimited line containing the boundary; an LF belongs to
  the line it terminates.
- `line-byte-start`: logical UTF-8 byte offset of that line's first byte.
- `char-column`: Unicode scalar count from the line start to the boundary.
- `utf16-column`: UTF-16 code-unit count from the line start to the boundary.

For `"a\n"`, whose UTF-8 bytes are `#"a\n"`:

| Byte | Location |
|---:|---|
| 0 | line 0, line start 0, char column 0, UTF-16 column 0 |
| 1 | line 0, line start 0, char column 1, UTF-16 column 1 |
| 2 | EOF on line 1, line start 2, char column 0, UTF-16 column 0 |

The trailing LF creates the empty final line, so line 1/UTF-16 column 0 resolves
to byte 2. For `"a\r\n"`, CR is an ordinary scalar: byte 1 is line 0 at columns
1/1, byte 2 is the LF at columns 2/2, and byte 3 is EOF on line 1. For `"😀x"`,
byte 0 is at columns 0/0, byte 4 is at columns 1/2, and byte 5 is EOF at columns
2/3. Resolving UTF-16 column 1, or locating a continuation byte 1 through 3, is
invalid because it is inside the supplementary scalar.

### Operations

In `tuna/api/operation.rkt`, keep the existing contract bindings and add:

```racket
(define byte-offset/c exact-nonnegative-integer?)

(contract-out
  [create-file-subject
   (->* []
        [#:file (or/c path-string? #f)
         #:text string?]
        positive-id/c)]
  [insert-subject-text
   (-> positive-id/c byte-offset/c string? void?)]
  [delete-subject-text
   (-> positive-id/c byte-offset/c byte-offset/c void?)]
  [replace-subject-text
   (-> positive-id/c byte-offset/c byte-offset/c string? void?)])
```

`create-file-subject` defaults `#:file` to `#f` and `#:text` to `""`.

### Queries

In `tuna/api/query.rkt`, add:

```racket
(define byte-offset/c exact-nonnegative-integer?)
(define immutable-string/c (and/c string? immutable?))

(contract-out
  [get-subject-text
   (-> positive-id/c immutable-string/c)]
  [get-subject-text-range
   (-> positive-id/c byte-offset/c byte-offset/c immutable-string/c)]
  [get-subject-text-byte-length
   (-> positive-id/c exact-nonnegative-integer?)]
  [locate-subject-text-byte
   (-> positive-id/c byte-offset/c text-location?)]
  [resolve-subject-text-position
   (-> positive-id/c
       exact-nonnegative-integer?
       exact-nonnegative-integer?
       byte-offset/c)])
```

`tuna/api/main.rkt` re-exports `text.rkt`. Existing `file-subject`, subject ID,
view, and generic `editor-changed` terminology remains unchanged.

### Text and notification semantics

- Mutable and immutable `string?` inputs are accepted. Tuna copies their value
  to immutable UTF-8 bytes before mutation; later mutation of the caller's string
  cannot affect subject text.
- Full and ranged reads return immutable strings whose contents cannot change
  after later edits.
- All offsets are logical UTF-8 byte offsets. Ranges are half-open and every
  endpoint must be an in-range Unicode scalar boundary.
- Lines and UTF-16 columns are zero-based. LF alone starts a line. Resolving a
  surrogate interior is invalid.
- Mutations return `void`; private change sets and reversal handles do not cross
  the public API.
- A missing subject, malformed argument, invalid range, or invalid location does
  not mutate text. It emits no event when its exception escapes the outer update.
  If user code catches that exception and the outer update later commits, the
  existing one-event-per-successful-update behavior still applies.
- Every valid mutation call uses the existing successful-update notification
  behavior, including an empty edit discarded by `buffer-content` and a
  byte-identical nonempty replacement.

## Ownership and lookup

The editor runtime owns one mutable hash from subject ID to opaque
`buffer-content`. The existing editor lock guards every lookup, creation, read,
and mutation.

- The hash starts empty.
- Lookup first confirms that the file subject exists in the active candidate
  state during an update, or in committed state otherwise.
- The first text access prepares empty `buffer-content` before changing the map.
- After preparing content, an update preallocates its created-ID journal slot.
  One callback-free break-disabled extent registers that slot before publishing
  the runtime-map entry. Cleanup may remove a registered ID whose entry was
  never published.
- Outside an update, publication remains under the editor lock and uses the same
  prepare-before-publish ordering without journal registration.
- A successful `create-file-subject #:text text` creates the state record and
  initializes its live content during the same outer update.
- Stopping the editor releases the live map with the runtime.
- Loading editor state recreates no text. A restored file subject receives empty
  live content on first access.

Mutable text is not stored in `editor-state`, written to the state file, or sent
to the asynchronous state snapshot worker. The state-file schema and worker are
unchanged.

## Update and failure ordering

Text mutations run inside the existing `call-with-editor-update` boundary.
Nested operations observe prior edits from the same outer update. Extend the
private update context with:

- a LIFO of preallocated reversal slots;
- a LIFO or set of subject IDs registered before lazy map publication;
- an `active`, `committed`, or `aborted` state.

Wrap the outer update body in a continuation barrier. Active-context lookup also
requires the context state to be `active`. A captured continuation cannot reenter
an update after commit or cancellation; an attempted re-entry raises and cannot
publish state or an event.

### Mutation publication

For one text mutation:

1. Validate public arguments and copy/encode replacement text before mutation.
2. Resolve the subject against the active candidate state.
3. Preallocate and register an empty reversal slot at the journal head.
4. Apply the edit through a reversible `buffer-content` entry point.
5. In the mutation's final callback-free break-disabled extent, publish the
   opaque reversal handle into the registered slot before a break can escape.
6. Return `void`; the slot remains private until outer completion.

If preparation or mutation fails, `buffer-content` restores its own logical
bytes and leaves the slot empty.

### Cancellation

If the outer update exits before commit because of an exception, break, or
nonlocal escape, its `dynamic-wind` cleanup runs under the editor lock:

1. Mark the context `aborted` and disable breaks.
2. Pop journal slots newest-first. The update layer checks LIFO order; the
   low-level reversal checks handle ownership and one-shot use.
3. Reverse every populated slot.
4. Remove every registered lazy content ID, whether or not publication reached
   the runtime map.
5. Continue the original exit.

Reversal uses already-prepared inverse splices. It performs no coordinate or edit
revalidation and no capacity allocation. It restores logical bytes and line
index correctness, invalidates the snapshot cache, and need not restore gap
placement, capacity, or snapshot object identity.

### Commit and post-commit work

After the body returns, validate the candidate state and runtime-content
invariants. Runtime-content validation is structural: map keys must name file
subjects in candidate state, values must satisfy `buffer-content?`, and journal
entries must refer by object identity to their expected content. Validation never
reads, snapshots, or copies whole text.

Then, in one callback-free break-disabled commit point:

1. Publish the candidate state to the editor state box.
2. Mark the update context `committed`.

Only after that point request the existing metadata snapshot and emit the
existing generic event, retaining their current order. A raise or break from
post-commit snapshot/event work propagates but cannot reverse committed metadata
or text. If the snapshot requester raises before notification, the event is not
emitted; this plan does not redesign post-commit delivery.

On ordinary success, discard the transient journal. It adds no revision counter
and records no user-visible history.

## Private adapter contract

Add `tuna/api/private/text.rkt`. It owns string copying/UTF-8 conversion, private
edit construction, runtime-content lookup, reversal-slot registration, and
mapping of private locations. It exports this concrete internal surface:

```racket
(define positive-id/c (and/c exact-integer? positive?))
(define byte-offset/c exact-nonnegative-integer?)
(define immutable-string/c (and/c string? immutable?))

(contract-out
  [subject-text-initialize!
   (-> positive-id/c string? void?)]
  [subject-text-insert!
   (-> positive-id/c byte-offset/c string? void?)]
  [subject-text-delete!
   (-> positive-id/c byte-offset/c byte-offset/c void?)]
  [subject-text-replace!
   (-> positive-id/c byte-offset/c byte-offset/c string? void?)]
  [subject-text
   (-> positive-id/c immutable-string/c)]
  [subject-text-range
   (-> positive-id/c byte-offset/c byte-offset/c immutable-string/c)]
  [subject-text-byte-length
   (-> positive-id/c exact-nonnegative-integer?)]
  [subject-text-locate-byte
   (-> positive-id/c
       byte-offset/c
       (values exact-nonnegative-integer?
               exact-nonnegative-integer?
               exact-nonnegative-integer?
               exact-nonnegative-integer?))]
  [subject-text-resolve-position
   (-> positive-id/c
       exact-nonnegative-integer?
       exact-nonnegative-integer?
       byte-offset/c)])
```

The four mutators require an active update; public operations establish it.
`subject-text-initialize!` is called only after the candidate state contains the
new subject. The five query functions use candidate state when an update is
active and committed state otherwise. Public operation/query wrappers contain no
storage or cancellation logic.

## Private storage extension

Extend `tuna/api/private/buffer-content.rkt` with a reversible mutation path that
reuses each prepared operation's deleted bytes and LF data.

- A reversal handle is opaque, tied to its originating content, and usable once.
- The caller preallocates and journals the publication slot before mutation.
- Publishing the handle is part of the successful mutation's final callback-free
  break-disabled extent.
- Update cancellation pops only the journal head, enforcing LIFO; low-level
  reversal rejects a wrong owner or consumed handle.
- Reversal uses prepared inverse splices with breaks disabled, performs no
  coordinate/edit revalidation or capacity allocation, invalidates the content
  snapshot cache, and consumes the handle.
- The existing `buffer-content-apply!` remains the ordinary low-level entry point
  and exposes no handle.
- Rename the local `marker` splice-progress counter to `completed-splices` or an
  equally unambiguous name. It is not an editor marker.

Do not take a whole-buffer snapshot to support cancellation.

All new fault-injection controls live only in test submodules of the private
modules. Production exports accept no injection callback, and canonical lazy
publication, reversal publication, and commit extents remain callback-free.

## Implementation tasks

### Task 1: reversible low-level mutation

Files:

- `tuna/api/private/buffer-content.rkt`
- `tuna-test/tuna/api/private/buffer-content.rkt`

Work and tests:

- Add opaque one-shot reversal handles and preallocated-slot publication.
- Reuse prepared inverse data without changing validation, batch ordering,
  capacity, or internal failure rollback.
- Test insert, delete, replacement, equal-position batches, Unicode, LF-index
  changes, growth, retained snapshots, wrong-owner, one-shot, and strict LIFO
  cancellation.
- Through test-submodule hooks only, inject exceptions and breaks before and
  after reversal publication; failed edits leave the slot empty and logical
  content unchanged.
- Reverse several completed mutations newest-first and compare every intermediate
  state with the flat oracle.
- Rename the splice-progress counter.

Focused commands:

```sh
raco test tuna-test/tuna/api/private/buffer-content.rkt
raco test tuna-test/tuna/api/private/buffer-content-benchmark.rkt
git diff --check
for file in tuna/api/private/buffer-content.rkt \
            tuna-test/tuna/api/private/buffer-content.rkt; do
  output=$(git diff --no-index --check /dev/null "$file" 2>&1)
  status=$?
  if [ "$status" -gt 1 ] || [ -n "$output" ]; then
    printf '%s\n' "$output"
    exit 1
  fi
done
```

Gate:

- Focused tests pass.
- Existing benchmark workloads and thresholds remain unchanged. Rerun the
  authoritative benchmark if the ordinary mutation hot path changes.
- A fresh correctness reviewer approves publication, reversal ordering,
  break handling, and the absence of whole-buffer copies.

### Task 2: runtime integration and private adapter

Files:

- `tuna/api/private/runtime.rkt`
- `tuna/api/private/update.rkt`
- `tuna/api/private/text.rkt` (new)
- `tuna-test/tuna/api/private/text.rkt` (new)
- `tuna-test/tuna/command.rkt`
- `tuna-test/tuna/events.rkt`

Work and tests:

- Add the lazy runtime subject-content hash and the exact private adapter above.
- Add registered-before-published lazy entry creation with boundary fault
  injection exported only by the private module's test submodule.
- Test exception and break injection after content preparation, after created-ID
  registration, and after map publication. Cancellation removes published and
  registered-but-unpublished IDs.
- Add the update status, continuation barrier, reversal LIFO, and break-disabled
  state/flag commit point.
- Test nested read-your-writes and external lock isolation.
- Test exceptions, breaks, and nonlocal escapes after edits to one or several
  subjects: text and metadata restore together and no event is emitted.
- Capture a continuation inside an update, abort it, then attempt re-entry. Re-entry
  is rejected and cannot commit text, metadata, or an event.
- Inject snapshot requester raises and breaks after the commit point. Metadata and
  text remain committed; current snapshot-before-event ordering is observed.
- Test caught invalid operations: the invalid call changes no text, while a later
  successful outer commit still emits the normal single event.

Focused commands:

```sh
raco test tuna-test/tuna/api/private/text.rkt \
          tuna-test/tuna/command.rkt \
          tuna-test/tuna/events.rkt
git diff --check
for file in tuna/api/private/text.rkt \
            tuna-test/tuna/api/private/text.rkt; do
  output=$(git diff --no-index --check /dev/null "$file" 2>&1)
  status=$?
  if [ "$status" -gt 1 ] || [ -n "$output" ]; then
    printf '%s\n' "$output"
    exit 1
  fi
done
```

Gate:

- Focused tests pass.
- A fresh correctness reviewer approves lazy publication, terminal cancellation,
  commit ordering, lock ownership, and every exit path.
- A fresh scope reviewer confirms the journal is only existing update plumbing,
  not undo, revisions, or retained history.

### Task 3: public basic text API

Files:

- `tuna/api/text.rkt` (new)
- `tuna/api/operation.rkt`
- `tuna/api/query.rkt`
- `tuna/api/main.rkt`
- `tuna-test/tuna/api.rkt`
- `tuna-test/tuna/text.rkt` (new)

Work and tests:

- Add the exact public contracts and hidden constructor described above.
- Add initial text to `create-file-subject` without changing immutable metadata.
- Keep public wrappers thin over `private/text.rkt`.
- Test empty, ASCII, BMP, supplementary, LF, CRLF, and trailing-LF text.
- Test full/range immutable reads, byte length, insertion, deletion, replacement,
  location examples, and location round trips.
- Test out-of-range, non-scalar, continuation-byte, and surrogate-interior
  rejection.
- Pass mutable strings to create, insert, and replace; mutate each caller-owned
  string afterward and prove stored text is unchanged.
- Retain returned strings across edits and prove they are immutable and unchanged.
- Test valid discarded empty edits and byte-identical replacements follow current
  successful-update notification behavior.
- Test missing subjects fail without creating an observable live entry.
- Test state-file serialization remains metadata-only and a restored subject's
  first text read is empty.

Focused commands:

```sh
raco test tuna-test/tuna/text.rkt tuna-test/tuna/api.rkt
git diff --check
for file in tuna/api/text.rkt tuna-test/tuna/text.rkt; do
  output=$(git diff --no-index --check /dev/null "$file" 2>&1)
  status=$?
  if [ "$status" -gt 1 ] || [ -n "$output" ]; then
    printf '%s\n' "$output"
    exit 1
  fi
done
```

Gate:

- Focused tests pass.
- A fresh API reviewer approves exports, contracts, location semantics, copying,
  errors, and the absence of private structure leakage.

### Task 4: documentation and complete validation

Files:

- `docs/architecture.org`
- `docs/roadmap.org`
- `docs/notes/text-model-note.md`
- `docs/plans/gap-buffer-plan.md`
- `docs/plans/editable-buffer-api-plan.md`
- `docs/adr/0002-runtime-owned-subject-text.md`

Work:

- Record the implemented runtime ownership and public surface.
- Mark the editable-buffer roadmap item complete only after every prior gate
  passes.
- Keep file lifecycle and interactive editing in their existing later roadmap
  items.

Validation commands:

```sh
make format
raco test tuna-test/tuna/api/private/buffer-content.rkt \
          tuna-test/tuna/api/private/buffer-content-benchmark.rkt \
          tuna-test/tuna/api/private/text.rkt \
          tuna-test/tuna/text.rkt \
          tuna-test/tuna/api.rkt \
          tuna-test/tuna/command.rkt \
          tuna-test/tuna/events.rkt
make test
make review
git diff --check
for file in docs/adr/0002-runtime-owned-subject-text.md \
            docs/plans/gap-buffer-plan.md \
            docs/plans/editable-buffer-api-plan.md \
            tuna/api/text.rkt \
            tuna/api/private/text.rkt \
            tuna-test/tuna/text.rkt \
            tuna-test/tuna/api/private/text.rkt; do
  output=$(git diff --no-index --check /dev/null "$file" 2>&1)
  status=$?
  if [ "$status" -gt 1 ] || [ -n "$output" ]; then
    printf '%s\n' "$output"
    exit 1
  fi
done
git diff --cached --quiet
```

Gate:

- Every command passes with no new review warning.
- No staged files are introduced.
- Final fresh correctness and scope/API reviewers report no blockers.

## Non-goals

- File visit, save, revert, external-change handling, or file decoding
- Dirty state, autosave, recovery, or persistence of subject text
- State-file schema or snapshot-worker changes
- Event payloads, content-specific events, or notification redesign
- Public transactions, edit batches, change sets, or reversal handles
- Revisions, modification counters, or background-result guards
- Undo or redo
- Point, mark, markers, anchors, selections, or narrowing
- Text properties, overlays, syntax metadata, or derived caches
- View editing state, text rendering, or interactive input handling
- Alternate text providers or runtime-selectable representations
- Renaming subjects, file subjects, IDs, or existing public subject operations

## Review loop

Run each task with one writer and fresh read-only reviewers:

1. A scout confirms the current file/call graph and exact test targets.
2. One worker is the only process editing the worktree.
3. The worker runs the focused and complete validation commands before handoff.
4. Correctness and scope/API reviewers run in parallel without editing.
5. Return concrete findings to the same worker and repeat. Stop after approval or
   three review rounds.

Do not begin a later task while the current task has a blocker. Any new public
semantic or representation choice returns to the owner before implementation.
