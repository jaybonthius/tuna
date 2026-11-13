#!tuna
(import (modes))

(define-table keymap "Keys in buffers of programs.")
(define-hook mode-hook "Called in each buffer that turns on a programming mode.")

(modes:define-major-mode mode
  (lighter "Prog")
  (keymap keymap)
  (hook mode-hook))
