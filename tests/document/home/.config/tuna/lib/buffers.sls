#!tuna
(import (document) (jobs))

(define (make text) (vector 0 (document:from-datum text)))

(define (version buffer) (vector-ref buffer 0))

(define (document buffer) (document:freeze (vector-ref buffer 1) jobs:freeze))

(define (replace! buffer start end text)
  (vector-set! buffer 0 (+ (vector-ref buffer 0) 1))
  (vector-set! buffer 1 (document:replace (vector-ref buffer 1) start end (document:from-datum text))))
