#!tuna
(import (files))

(define (x) 1)

(set! files:save! (lambda (path) 'boom))
(on-unload (lambda () (display "boom unloading") (newline)))
(car '())
