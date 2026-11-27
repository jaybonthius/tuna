#!tuna
(import (tables))
(tables:define-table global)
(define (bind! keymap key command) (tables:set! keymap key command))
(define (unbind! keymap key) (tables:remove! keymap key))
