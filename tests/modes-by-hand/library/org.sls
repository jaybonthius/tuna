#!tuna
(import (modes))

(define-table keymap "Keys in Org buffers.")
(define-hook mode-hook "Called in each buffer that turns on org:mode.")

(modes:define-major-mode mode
  (lighter "Org")
  (keymap keymap)
  (hook mode-hook))
