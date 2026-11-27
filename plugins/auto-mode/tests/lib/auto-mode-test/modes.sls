#!tuna
(import (modes) (hooks) (tables))

(tables:define-table archive-keymap "Keys in archive listings.")
(hooks:define-hook archive-hook "Called in each buffer that turns on archive mode.")
(modes:define-major-mode archive (lighter "Archive") (keymap archive-keymap) (hook archive-hook))

(tables:define-table make-keymap "Keys in makefiles.")
(hooks:define-hook make-hook "Called in each buffer that turns on make mode.")
(modes:define-major-mode make (lighter "Make") (keymap make-keymap) (hook make-hook))

(tables:define-table html-keymap "Keys in HTML buffers.")
(hooks:define-hook html-hook "Called in each buffer that turns on HTML mode.")
(modes:define-major-mode html (lighter "HTML") (keymap html-keymap) (hook html-hook))
