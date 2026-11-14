#!tuna
(import (modes))

(define-table keymap "Keys in Python buffers.")
(define-hook mode-hook "Called in each buffer that turns on Python mode.")

(modes:define-major-mode mode
  (lighter "Python")
  (keymap keymap)
  (hook mode-hook))
