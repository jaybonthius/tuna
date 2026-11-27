#!tuna
(import (timers))
(define %self (current-owner))
(define %redraws 0)

(define (redraws) %redraws)
(define %timer #f)

(define (redraw ended)
  (set! %redraws (+ %redraws 1))
  (call-as-owner %self (lambda () (unless %timer
      (set! %timer (timers:run-after 60 void)))))
  (ended))

(advice-add! batch-ended redraw)
