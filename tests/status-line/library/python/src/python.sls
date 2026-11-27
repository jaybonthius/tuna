#!tuna
(import (modes) (hooks) (tables))

(tables:define-table keymap "Keys in Python buffers.")
(hooks:define-hook mode-hook "Called in each buffer that turns on Python mode.")

(modes:define-major-mode mode
  (lighter "Python")
  (keymap keymap)
  (hook mode-hook))
