(library (syntax-error)
  (export f)
  (import (chezscheme))
  (define (f) (let ((x)) x)))
