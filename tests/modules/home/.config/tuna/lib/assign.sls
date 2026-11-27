#!tuna
(define %count 0)
(define (count) %count)
(define (bump!) (set! %count (+ %count 1)) %count)
(define-record-type thing (fields a))
