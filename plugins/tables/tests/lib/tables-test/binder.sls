#!tuna
(import (tables))

(define (table) (eval 'keymap (interaction-environment)))

(tables:set! (table) 'k 'binder)
