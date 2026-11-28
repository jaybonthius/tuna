#!tuna
(import (modes) (prog) (modes-test fill) (hooks) (options) (tables))

(tables:define-table keymap "Keys in code buffers.")
(hooks:define-hook mode-hook "Called in each buffer that turns on code mode.")

(modes:define-major-mode mode
  (parent prog:mode)
  (lighter "Code")
  (keymap keymap)
  (hook mode-hook))

(define (setup)
  (options:set-local! modes-test/fill:column 79))

(hooks:add! mode-hook setup)
