#!tuna
(import (prog) (hooks) (options))

(options:define-option width 8 fixnum? "Columns of one level of indentation.")

(define (setup) (options:set-local! width 2))

(hooks:add! prog:mode-hook setup)
