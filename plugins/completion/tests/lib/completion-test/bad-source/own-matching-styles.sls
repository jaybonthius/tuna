#!tuna
(import (completion))

(define source (completion:source (stream (lambda (emit) (lambda (input) #f))) (own-matching) (styles '())))
