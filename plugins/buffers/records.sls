(library (buffers records)
  (export make-buffer-record buffer-record? buffer-name buffer-name-set! buffer-doc buffer-doc-set!
          buffer-frozen? buffer-frozen?-set! buffer-version buffer-version-set! buffer-save-stamp
          buffer-save-stamp-set! buffer-log buffer-log-set!
          buffer-logged buffer-logged-set! buffer-scope buffer-scope-set! buffer-layers buffer-layers-set!
          buffer-anchors buffer-bare buffer-bare-set! buffer-silent? buffer-silent?-set!
          make-edit-record edit-record? edit-record-version edit-record-start edit-record-removed
          edit-record-inserted edit-record-removed-length edit-record-inserted-length edit-record-moves?
          edit-record-silent?
          make-piece-record piece-record? piece-record-document piece-record-spans
          make-kind-entry kind-entry? kind-entry-name kind-entry-content kind-entry-inline? kind-entry-sticky
          kind-entry-stops kind-entry-draw kind-entry-keymap kind-entry-consent kind-entry-whole? kind-entry-isolating?
          kind-entry-text kind-entry-owner
          make-layer-type layer-type? layer-type-name layer-type-priority layer-type-sticky
          layer-type-evaporate? layer-type-travels? layer-type-read-only? layer-type-keymap
          make-layer buffer-layer? buffer-layer-buffer buffer-layer-type buffer-layer-key buffer-layer-store
          buffer-layer-seen buffer-layer-seen-set!
          make-anchor buffer-anchor? buffer-anchor-buffer buffer-anchor-after? buffer-anchor-position
          buffer-anchor-position-set! buffer-anchor-version buffer-anchor-version-set!
          buffer-anchor-deleted? buffer-anchor-deleted?-set!
          &refused make-refused-condition refused-condition?)
  (import (chezscheme))

  ;; Buffers, edits, pieces, layers and anchors outlive a reload of
  ;; (buffers) in other code's variables, and the kinds and layer types
  ;; other owners defined stay in its tables. Compiling a record definition
  ;; makes a new type, so a reload of changed source would leave them all
  ;; foreign; this library is created once per process and keeps the types.
  (define-record-type (buffer make-buffer-record buffer-record?)
    (sealed #t)
    (fields (mutable name) (mutable doc) (mutable frozen?) (mutable version) (mutable save-stamp)
            (mutable log) (mutable logged) (mutable scope) (mutable layers) anchors (mutable bare)
            (mutable silent?))
    (protocol
      (lambda (new)
        (lambda (name doc scope silent?)
          (new name doc #f 0 0 (make-vector 16 #f) 0 scope '() (make-weak-eq-hashtable) '(#f . #f) silent?)))))

  ;; Anchors and the log's trim map positions through thousands of edits,
  ;; so an edit keeps its lengths and whether it moves positions at all.
  (define-record-type edit-record
    (sealed #t)
    (fields version start removed inserted removed-length inserted-length moves? silent?))

  (define-record-type piece-record
    (sealed #t)
    (fields document spans))

  (define-record-type kind-entry
    (sealed #t)
    (fields name content inline? sticky stops draw keymap consent whole? isolating? text owner))

  (define-record-type layer-type
    (sealed #t)
    (fields name priority sticky evaporate? travels? read-only? keymap))

  (define-record-type (buffer-layer make-layer buffer-layer?)
    (sealed #t)
    (fields buffer type key store (mutable seen)))

  (define-record-type (buffer-anchor make-anchor buffer-anchor?)
    (sealed #t)
    (fields buffer after? (mutable position) (mutable version) (mutable deleted?)))

  (define-condition-type &refused &error make-refused-condition refused-condition?)

  (record-writer (record-type-descriptor buffer)
    (lambda (b p wr) (fprintf p "#<buffer ~a>" (buffer-name b))))

  (record-writer (record-type-descriptor edit-record)
    (lambda (e p wr) (fprintf p "#<edit ~a>" (edit-record-version e))))

  (record-writer (record-type-descriptor piece-record)
    (lambda (p port wr) (display "#<piece>" port)))

  (record-writer (record-type-descriptor kind-entry)
    (lambda (k p wr) (fprintf p "#<kind ~a>" (kind-entry-name k))))

  (record-writer (record-type-descriptor buffer-layer)
    (lambda (l p wr) (fprintf p "#<layer ~a>" (buffer-layer-type l))))

  (record-writer (record-type-descriptor buffer-anchor)
    (lambda (a p wr) (fprintf p "#<anchor>"))))
