#!tuna
(import (modes) (hooks) (tables))

(tables:define-table keymap "Keys in HTML buffers.")
(hooks:define-hook mode-hook "Called in each buffer that turns on HTML mode.")

(modes:define-major-mode mode
  (lighter "HTML")
  (keymap keymap)
  (hook mode-hook))
