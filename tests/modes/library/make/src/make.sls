#!tuna
(import (modes) (auto-mode) (hooks) (tables))

(tables:define-table keymap "Keys in makefiles.")
(hooks:define-hook mode-hook "Called in each buffer that turns on Make mode.")

(modes:define-major-mode mode
  (lighter "Make")
  (keymap keymap)
  (hook mode-hook))
