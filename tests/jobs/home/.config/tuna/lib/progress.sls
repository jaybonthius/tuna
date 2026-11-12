;; Shared state a job and the configuration both see, which a worker's
;; libraries must not keep outside a test: it shows how far a job got.
(library (progress)
  (export count! counted)
  (import (chezscheme))
  (define mutex (make-mutex))
  (define n 0)
  (define (count!) (with-mutex mutex (set! n (+ n 1))))
  (define (counted) (with-mutex mutex n)))
