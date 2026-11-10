#!tuna
(module helpers (twice) (define (twice x) (* 2 x)))
(import helpers)
(module counter (n bump!) (define n 0) (define (bump!) (set! n (+ n 1))))
(import counter)
(define (count) (bump!) n)
(define (text) "scoped")
