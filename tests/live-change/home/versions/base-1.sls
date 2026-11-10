#!tuna
(define (f) 1)
(define (g) 'g)

(on-unload (lambda () (display "base unloading ")))
