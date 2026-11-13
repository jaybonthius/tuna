#!tuna
(import (modes) (auto-mode))

(define-table keymap "Keys in archive listings.")
(define-hook mode-hook "Called in each buffer that turns on Archive mode.")

(modes:define-major-mode mode
  (lighter "Archive")
  (keymap keymap)
  (hook mode-hook))

(for-each (lambda (name) (table-set! auto-mode:file-names name mode)) '("tar.gz" "zip"))
