#!tuna
(import (editing))

(define %typed 0)

(define (typed) %typed)

(define (count-typed self-insert n char)
  (set! %typed (+ %typed n))
  (self-insert n char))

(advice-add! editing:self-insert count-typed)
