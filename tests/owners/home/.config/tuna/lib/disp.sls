#!tuna
(define redraws 0)
(define timer #f)

(define (redraw ended)
  (set! redraws (+ redraws 1))
  (as-module (this-module)
    (unless timer
      (set! timer (run-with-timer 60 void))))
  (ended))

(advice-add! batch-ended redraw)
