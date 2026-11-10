#!tuna
(import (spell))

(define (go) (spell:check "z"))

(on-unload (lambda () (display "speller unloading")))
