#!tuna
(import (modes) (auto-mode) (prog) (editing))

(define-table keymap "Keys in Python buffers.")
(define-hook mode-hook "Called in each buffer that turns on Python mode.")

(modes:define-major-mode mode
  (parent prog:mode)
  (lighter "Python")
  (keymap keymap)
  (hook mode-hook))

(define (setup)
  (set-option-local! editing:word-characters "_"))

(add-hook! mode-hook setup)
(for-each (lambda (name) (table-set! auto-mode:file-names name mode))
          '("py" "pyi" "pyw"))
(table-set! auto-mode:interpreters "python" mode)
