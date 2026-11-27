#!tuna
(import (timers))
(define %redraws 0)
(define %timer #f)

(define (redraws) %redraws)

(define (redraw ended)
  (set! %redraws (+ %redraws 1))
  (unless %timer (set! %timer (timers:run-after 60 void)))
  (ended))

(advice-add! batch-ended redraw)
