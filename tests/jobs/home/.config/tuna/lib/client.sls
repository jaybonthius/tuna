#!tuna
(import (jobs))

(jobs:define-worker (echo x emit) (emit x))

(jobs:define-worker (wait-forever x emit receive) (receive))

(jobs:define-worker (fails x emit) (car x))

(define %from-the-body '())

(define (from-the-body) %from-the-body)

(define (start-waiting on-end)
  (jobs:start wait-forever 0 void on-end))

(jobs:start echo 'started-in-the-body
  (lambda (v) (set! %from-the-body (cons v %from-the-body))))
