#!tuna
(import (fill))
(define-hook mode-hook)
(define (indent-buffer . args) (display "indenting "))
(define (mode) (mode-hook))
(set-option! fill:column 90)
