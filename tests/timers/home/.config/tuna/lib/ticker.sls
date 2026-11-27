#!tuna
(import (timers))
(define %count 0)

(define (count) %count)

(define timer (timers:run-after 0.05 (lambda () (set! %count (+ %count 1))) 0.05))
