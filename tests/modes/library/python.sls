#!tuna
(import (modes) (auto-mode) (prog) (syntax) (fill) (hooks) (options) (tables))

(tables:define-table keymap "Keys in Python buffers.")
(hooks:define-hook mode-hook "Called in each buffer that turns on Python mode.")

(modes:define-major-mode mode
  (parent prog:mode)
  (lighter "Python")
  (keymap keymap)
  (hook mode-hook))

(define (setup)
  (options:set-local! fill:column 79))

(hooks:add! mode-hook setup)
(tables:set! syntax:word-characters mode "")
(tables:set! syntax:symbol-characters mode "_")
(for-each (lambda (name) (tables:set! auto-mode:file-names name mode))
          '("py" "pyi" "pyw"))
(tables:set! auto-mode:interpreters "python" mode)
