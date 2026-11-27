#!tuna
(import (fill) (hooks) (options))
(hooks:define-hook mode-hook)
(define (indent-buffer . arguments) (display "[indenting]"))
(define (mode) (mode-hook))
(options:set! fill:column 90)
