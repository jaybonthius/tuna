;;; Shared vocabulary: identities (ADR 4, ADR 12).
prelude: :gerbil/core

(export next-id!)

(def id-mutex (make-mutex 'tuna-ids))
(def last-id 0)

;; Identities are unique for the life of the process; the lock keeps them
;; unique when request threads allocate them too.
(def (next-id!) => :fixnum
  (:- (do-with-lock id-mutex
        (set! last-id (fx1+ last-id))
        last-id)
      :fixnum))
