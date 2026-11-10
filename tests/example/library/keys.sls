#!tuna
(define-table global "Key bindings that apply everywhere.")
(define (bind! keymap key command) (table-set! keymap key command))
(define (unbind! keymap key) (table-remove! keymap key))
