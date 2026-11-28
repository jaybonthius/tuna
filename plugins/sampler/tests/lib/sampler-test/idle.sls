#!tuna
(import (jobs) (sampler))

(jobs:define-worker (%quiet input emit receive)
  (let loop ()
    (receive)
    (emit (cons 0.0 #f))
    (loop)))

(define (%ignore time data) (void))

(sampler:define-source idle %quiet (lambda () #f) %ignore)
