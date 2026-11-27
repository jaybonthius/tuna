#!tuna
(import (modes) (hooks) (tables))

(tables:define-table keymap "Keys.")
(hooks:define-hook mode-hook "Setup.")
(modes:define-major-mode mode (keymap keymap) (hook mode-hook) (language "python"))
