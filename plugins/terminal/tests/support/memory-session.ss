;;; A session provider that keeps what it saves in memory, across fresh
;;; kernels, so a test can stop one Tuna and start another from its
;;; session, as a restart does.
(import (only-in :gerbil/runtime/hash HashTable)
        :tuna/kernel
        (only-in :tuna/plugins/session/contract session-service session-slot-name session-slot-save
                 session-slot-restore))
(export memory-session
        forget-memory-session!)

;; Slot name -> data, as the last save left it.
(def saved (make-hash-table-eq))

(def (forget-memory-session!) => :void
  (hash-clear! saved))

(defstruct remembering-session ((slots : :list))
  final: #t)

(defmethod {add-session-slot! remembering-session}
  (lambda (self ctx slot priority)
    (set! (remembering-session-slots self) (append (remembering-session-slots self) [slot]))
    (context-defer! ctx (lambda ()
                          (set! (remembering-session-slots self)
                            (remq slot (remembering-session-slots self)))))))

(defmethod {save-session! remembering-session}
  (lambda (self)
    (for-each (lambda (slot) (hash-put! saved (session-slot-name slot) ((session-slot-save slot))))
              (remembering-session-slots self))))

(defmethod {restore-session! remembering-session}
  (lambda (self)
    (for-each (lambda (slot)
                (let (data (hash-get saved (session-slot-name slot)))
                  (when data ((session-slot-restore slot) data))))
              (remembering-session-slots self))))

(defmethod {state-directory remembering-session}
  (lambda (self) (error "This session keeps no files")))

(defplugin (memory-session ctx)
  "Provides a session kept in memory, across kernels."
  provides: [session-service]
  (context-provide! ctx session-service (make-remembering-session [])))
