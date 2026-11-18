#!tuna
(import (keys) (commands))

(define-table keymap "Plain keys.")

(commands:define-command (hello) "Says hello." (void))

(keys:bind! keymap "h" hello)
