#!tuna
(import (modes))

(define-table keymap "Keys.")
(define-hook mode-hook "Setup.")
(modes:define-major-mode mode (keymap keymap) (hook mode-hook) (language "python"))
