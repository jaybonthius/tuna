#!tuna
(import (modes) (auto-mode) (hooks) (tables))

(tables:define-table keymap "Keys in archive listings.")
(hooks:define-hook mode-hook "Called in each buffer that turns on Archive mode.")

(modes:define-major-mode mode
  (lighter "Archive")
  (keymap keymap)
  (hook mode-hook))

(for-each (lambda (name) (tables:set! auto-mode:file-names name mode)) '("tar.gz" "zip"))
