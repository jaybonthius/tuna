#!tuna
(import (prog))

(define-option width 8 fixnum? "Columns of one level of indentation.")

(define (setup) (set-option-local! width 2))

(add-hook! prog:mode-hook setup)
