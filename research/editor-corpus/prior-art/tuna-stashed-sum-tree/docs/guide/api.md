# Tuna buffer and text API

This guide uses only the public `tuna/api` interface. Text values are immutable and opaque; convert at the boundary with `string->text` and `text->string`.

## Walkthrough

```racket
#lang racket/base
(require tuna/api)

(define state-file "editor.state")
(dynamic-wind
  void
  (lambda ()
    (start-editor #:state-file state-file)

    (define buffer-id
      (create-buffer #:text (string->text "aé\n😀")
                     #:file "notes.txt"))
    (define view-a (create-view buffer-id))
    (define view-b (create-view buffer-id))
    (unless (and (= (get-view-buffer view-a) buffer-id)
                 (= (get-view-buffer view-b) buffer-id))
      (error 'example "views do not share the buffer"))

    (define snapshot-0 (get-buffer-snapshot buffer-id))
    (define text-0 (buffer-snapshot-text snapshot-0))
    (define line-1 (text-byte->position text-0 4))
    (unless
        (equal?
          (list (text-byte-length text-0)
                (text-char-length text-0)
                (text-utf-16-length text-0)
                (text-line-count text-0)
                (text-byte->char text-0 3)
                (text-char->byte text-0 2)
                (text-byte->utf-16 text-0 8)
                (text-utf-16->byte text-0 5)
                (text-byte->line text-0 4)
                (position-line line-1)
                (position-column line-1)
                (text-position->byte text-0 (position 1 0))
                (text-line-start-byte text-0 1))
          '(8 4 5 2 2 3 5 8 1 1 0 4 4))
      (error 'example "unexpected coordinate conversion"))

    (define events (subscribe-editor!))
    (define revision-1
      (insert-buffer-text
        buffer-id 3 (string->text "!")
        #:expected-revision (buffer-snapshot-revision snapshot-0)))
    (define event (sync events))
    (define change (car (editor-changed-buffer-changes event)))
    (unless (and (= (buffer-change-buffer-id change) buffer-id)
                 (= (buffer-change-before-revision change) 0)
                 (= (buffer-change-after-revision change) revision-1))
      (error 'example "unexpected change event"))
    (define change-set (buffer-change-change-set change))
    (unless (= (text-change-set-map-offset change-set 3 'after) 4)
      (error 'example "unexpected mapped offset"))
    (unsubscribe-editor! events)

    (unless (string=? (text->string text-0) "aé\n😀")
      (error 'example "old snapshot changed"))

    (with-handlers
        ([exn:fail:stale-buffer-revision?
          (lambda (error)
            (unless (and (= (exn:fail:stale-buffer-revision-buffer-id error)
                            buffer-id)
                         (= (exn:fail:stale-buffer-revision-expected error) 0)
                         (= (exn:fail:stale-buffer-revision-actual error)
                            revision-1))
              (raise error)))])
      (replace-buffer-text buffer-id 0 1 (string->text "A")
                           #:expected-revision 0))

    (define revision-2
      (replace-buffer-text*
        buffer-id
        (list (text-edit 0 0 (string->text "<"))
              (text-edit 4 5 (string->text "")))
        #:expected-revision revision-1))
    (unless (and (= revision-2 2)
                 (string=? (text->string (get-buffer-text buffer-id))
                           "<aé!😀"))
      (error 'example "unexpected batch result")))
  (lambda () (stop-editor)))
```

`get-buffer-snapshot` atomically pairs a text value with its revision. Retaining its text keeps that old value readable after later edits.

## Coordinates and batches

All edit positions are UTF-8 byte offsets and must fall on scalar boundaries. Use `text-valid-byte-offset?` or the byte/character/UTF-16/line conversion functions rather than deriving offsets from Racket string indexes.

`replace-buffer-text*` accepts ordered, non-overlapping `text-edit` values. Every start and end refers to the same old snapshot, not to an earlier edit's result. Multiple insertions at the same point are allowed and retain their input order.

An effective edit batch advances the buffer revision once and emits one `editor-changed` event containing its `buffer-change` and `text-change-set`. A normalized no-op keeps the revision and emits no buffer change event. Pass `#:expected-revision` for optimistic editing; a mismatch raises `exn:fail:stale-buffer-revision`, whose accessors report the buffer, expected revision, and actual revision.

## Lifecycle and persistence

`start-editor` installs the editor for calls on the current thread; `stop-editor` shuts it down. With `#:state-file`, startup loads existing logical state or initializes it when absent, each update requests a persistent snapshot, and shutdown flushes final state. The state-file datum grammar is private.

A buffer's optional `#:file` value is metadata returned by `get-buffer-file`. Tuna does not yet visit or save that file.

Current roadmap limits include per-view cursor and selection state, interactive buffer display and editing, undo/redo, file visit/save, markers, overlays, modes, and text UI.

See the decision record for [persistent text buffers](../adr/0002-persistent-text-buffers.md). The private text implementation is a client of the generic [SumTree package](../../sum-tree-docs/README.md).
