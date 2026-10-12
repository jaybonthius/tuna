;;; Shared vocabulary: identities, revision counters, change records, and
;;; spans (ADR 4, ADR 12).
prelude: :gerbil/core

(export next-id!
        (struct-out revision-counter)
        new-revision-counter
        revision-bump!
        (struct-out change)
        (struct-out span))

(def id-mutex (make-mutex 'tuna-ids))
(def last-id 0)

;; Identities are unique for the life of the process; the lock keeps them
;; unique when request threads allocate them too.
(def (next-id!) => :fixnum
  (:- (do-with-lock id-mutex
        (set! last-id (fx1+ last-id))
        last-id)
      :fixnum))

;; A monotonically increasing revision of one renderable object. Its owner
;; bumps it on the baton, so it needs no lock.
(defstruct revision-counter ((value : :fixnum))
  final: #t)

(def (new-revision-counter) => revision-counter
  (make-revision-counter 0))

(def (revision-bump! (counter : revision-counter)) => :fixnum
  (let (next (fx1+ (revision-counter-value counter)))
    (set! (revision-counter-value counter) next)
    next))

;; One edit of a text: at START, REMOVED was replaced by INSERTED, producing
;; character revision REVISION. Positions are 1-based. Markers, undo, and
;; jobs consume these records.
(defstruct change ((revision : :fixnum)
                   (start    : :fixnum)
                   (removed  : :string)
                   (inserted : :string))
  final: #t)

;; A range START..END of a text, 1-based and end-exclusive, carrying VALUE
;; (such as a face). Job results that rebase are lists of spans.
(defstruct span ((start : :fixnum)
                 (end   : :fixnum)
                 (value : :t))
  final: #t)
