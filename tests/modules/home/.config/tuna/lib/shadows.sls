#!tuna
(define (sleep seconds) (list 'slept seconds))
(define (exit) 'stayed)
(define (both) (list (sleep 1) (exit)))
