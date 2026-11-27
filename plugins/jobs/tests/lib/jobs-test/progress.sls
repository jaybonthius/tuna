;; A worker's libraries must keep no state, but this one does on purpose:
;; a job counts on it how far it got, and the test reads the count.
(library (jobs-test progress)
  (export count! counted)
  (import (chezscheme))
  (define mutex (make-mutex))
  (define n 0)
  (define (count!) (with-mutex mutex (set! n (+ n 1))))
  (define (counted) (with-mutex mutex n)))
