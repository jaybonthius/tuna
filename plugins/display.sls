#!tuna
(import (web) (layout) (haml))

;; Weak, so a client web has removed leaves no entry behind.
(define %failing (make-weak-eq-hashtable))

;; After a warning the code that raised it continues, so a guard here
;; lets a warning pass on to the core, which reports it and returns.
(define (%warning-only? c)
  (and (warning? c) (not (serious-condition? c))))

(define (%condition-text c)
  (call-with-string-output-port (lambda (p) (display-condition c p))))

;; A quit is not a failure: the user asked to stop work, and the next
;; batch draws this client again. The draw has succeeded once layout
;; returns; clearing the mark after the send instead would leave the
;; client marked when a quit lands between the two.
(define (%draw client)
  (guard (c [(quit-condition? c) (void)]
            [(not (%warning-only? c))
             (unless (hashtable-ref %failing client #f)
               (report c)
               (hashtable-set! %failing client #t))
             (web:send-screen! client (haml (:pre.display-error (%condition-text c))))])
    (let ([screen (layout:screen client)])
      (hashtable-delete! %failing client)
      (web:send-screen! client screen))))

;; A raise in the advice beneath must not stop the clients being drawn,
;; or every screen would freeze with nothing on it to act on.
(define (%redisplay ended)
  (guard (c [(not (%warning-only? c)) (report c)])
    (ended))
  (for-each %draw (web:clients)))

(advice-add! batch-ended %redisplay)
