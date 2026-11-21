#!tuna
(import (modes) (auto-mode) (prog) (syntax) (fill))

(define-table keymap "Keys in Python buffers.")
(define-hook mode-hook "Called in each buffer that turns on Python mode.")

(modes:define-major-mode mode
  (parent prog:mode)
  (lighter "Python")
  (keymap keymap)
  (hook mode-hook))

(define (setup)
  (set-option-local! fill:column 79))

(add-hook! mode-hook setup)
(table-set! syntax:word-characters mode "")
(table-set! syntax:symbol-characters mode "_")
(for-each (lambda (name) (table-set! auto-mode:file-names name mode))
          '("py" "pyi" "pyw"))
(table-set! auto-mode:interpreters "python" mode)
