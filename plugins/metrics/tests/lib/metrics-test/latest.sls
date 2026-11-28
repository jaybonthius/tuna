#!tuna
(import (metrics))

(define (latest-value m labels)
  (let ([p (metrics:latest m labels)]) (and p (cdr p))))
