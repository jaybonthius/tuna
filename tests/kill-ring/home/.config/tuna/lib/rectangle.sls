#!tuna
(import (buffers))

(buffers:define-kind block)

(define yanks '())

(define (yank-block buffer position piece)
  (set! yanks (cons position yanks))
  (buffers:insert! buffer position (buffers:piece-text piece)))
