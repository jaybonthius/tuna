#!tuna
(define count 0)
(define (bump!) (set! count (+ count 1)) count)
(define-record-type thing (fields a))
