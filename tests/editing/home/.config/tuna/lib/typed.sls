#!tuna
(import (editing))

(define typed 0)

(define (count-typed self-insert n)
  (set! typed (+ typed n))
  (self-insert n))

(advice-add! editing:self-insert count-typed)
