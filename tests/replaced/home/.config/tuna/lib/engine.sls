#!tuna
(define (run thunk) ((make-engine thunk) 1000 list list))
