#!tuna
(import (exit log) (exit keeper))
(define (say-leaving) (exit/log:note! "leaving the task"))
(on-unload (lambda () (exit/log:note! "user unloading")))
