#!tuna
(import (buffers) (kill-ring))

(buffers:define-kind block)

(define yanks '())

(define (yank-block buffer position piece)
  (set! yanks (cons position yanks))
  (kill-ring:insert! buffer position (kill-ring:text (list piece))))
