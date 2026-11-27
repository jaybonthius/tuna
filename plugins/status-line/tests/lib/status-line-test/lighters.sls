#!tuna
(import (modes) (hooks) (tables))

(tables:define-table wrap-keys "Keys while wrap mode is on.")

(modes:define-minor-mode wrap
  "Whether lines wrap."
  (lighter "Wrap")
  (keymap wrap-keys))

(tables:define-table script-keys "Keys in script buffers.")

(hooks:define-hook script-hook "Called in each buffer that turns on script mode.")

(modes:define-major-mode script
  (lighter "Script")
  (keymap script-keys)
  (hook script-hook))
