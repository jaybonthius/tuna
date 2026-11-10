#!tuna
(define count 0)

(define timer (run-with-timer 0.05 (lambda () (set! count (+ count 1))) 0.05))
