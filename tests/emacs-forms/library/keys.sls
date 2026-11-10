#!tuna
(define-table global)
(define (bind! keymap key command) (table-set! keymap key command))
(define (unbind! keymap key) (table-remove! keymap key))
