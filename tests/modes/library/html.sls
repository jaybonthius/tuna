#!tuna
(import (modes))

(define-table keymap "Keys in HTML buffers.")
(define-hook mode-hook "Called in each buffer that turns on HTML mode.")

(modes:define-major-mode mode
  (lighter "HTML")
  (keymap keymap)
  (hook mode-hook))
