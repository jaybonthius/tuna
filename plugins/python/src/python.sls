#!tuna
(import (modes) (prog) (auto-mode) (syntax) (hooks) (tables))

(tables:define-table keymap "Keys in Python buffers.")

(hooks:define-hook mode-hook "Called in each buffer that turns on python:mode.")

(modes:define-major-mode mode
  (parent prog:mode)
  (lighter "Python")
  (keymap keymap)
  (hook mode-hook)
  (language "python"))

(for-each (lambda (name) (tables:set! auto-mode:file-names name mode))
          '("py" "pyi" "pyw" "SConstruct" "SConscript"))
(tables:set! auto-mode:interpreters "python" mode)
(tables:set! syntax:word-characters mode "")
(tables:set! syntax:symbol-characters mode "_")
