#!tuna
(import (jobs) (test-runner))

(define (finished worker input)
  (let ([results '()] [ended #f])
    (jobs:start worker input
      (lambda (v) (set! results (cons v results)))
      (lambda (how) (set! ended (list how))))
    (test-runner:wait-until (lambda () ended))
    (list (reverse results) (car ended))))

(define (reports-during expected thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (thunk)
    (test-runner:wait-until (lambda () (>= (length reported) expected)))
    (advice-remove! report keep)
    (reverse reported)))
