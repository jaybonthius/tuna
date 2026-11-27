#!tuna
(import (modes) (auto-mode) (jobs) (faces) (syntax-highlighting) (hooks) (tables))

(tables:define-table keymap "Keys in log buffers.")
(hooks:define-hook mode-hook "Called in each buffer that turns on log mode.")
(modes:define-major-mode mode
  (lighter "Log")
  (keymap keymap)
  (hook mode-hook))

(jobs:define-worker (%highlighter input emit receive)
  (import (syntax-highlighting job) (syntax-highlighting-test log-highlight))
  (serve input emit receive highlight))

(tables:set! syntax-highlighting:highlighters mode
  (syntax-highlighting:make-highlighter %highlighter (list syntax-highlighting:faces)
    (lambda (buffer data) faces:comment)))
(tables:set! auto-mode:file-names "log" mode)
