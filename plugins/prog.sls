#!tuna
(import (modes) (hooks) (tables))

(tables:define-table keymap
  "Keys in every buffer whose major mode derives from prog:mode, searched after the language's own keymap.")

(hooks:define-hook mode-hook
  "Called in each buffer that turns on a mode derived from prog:mode, before the language's own hook.")

(modes:define-major-mode mode
  (lighter "Prog")
  (keymap keymap)
  (hook mode-hook))
