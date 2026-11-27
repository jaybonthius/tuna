#!tuna
(import (jobs) (test-runner))

(define (finished worker input)
  (let ([results '()] [ended #f])
    (jobs:start worker input
      (lambda (v) (set! results (cons v results)))
      (lambda (how) (set! ended (list how))))
    (test-runner:wait-until (lambda () ended))
    (list (reverse results) (car ended))))

