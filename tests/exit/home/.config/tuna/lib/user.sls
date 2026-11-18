#!tuna
(import (keeper))
(define (say-leaving) (display "leaving the task") (newline))
(on-unload (lambda () (display "user unloading") (newline)))
