#!tuna
(import (modes) (prog) (auto-mode) (syntax))

(define-table keymap "Keys in Python buffers.")

(define-hook mode-hook "Called in each buffer that turns on python:mode.")

(modes:define-major-mode mode
  (parent prog:mode)
  (lighter "Python")
  (keymap keymap)
  (hook mode-hook)
  (language "python"))

(for-each (lambda (name) (table-set! auto-mode:file-names name mode))
          '("py" "pyi" "pyw" "SConstruct" "SConscript"))
(table-set! auto-mode:interpreters "python" mode)
(table-set! syntax:word-characters mode "_")
