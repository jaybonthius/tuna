#!tuna
(import (spell))

(define (go) (spell:with-words "z"))

(on-unload (lambda () (display "speller unloading")))
