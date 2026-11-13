#!tuna
(import (modes))

(define-table keymap "Keys in buffers of prose.")
(define-hook mode-hook "Called in each buffer that turns on text mode.")

(modes:define-major-mode mode
  (lighter "Text")
  (keymap keymap)
  (hook mode-hook))
