#!tuna
(import (rename (only (chezscheme) sleep dynamic-wind) (sleep chez:sleep) (dynamic-wind chez:dynamic-wind)))

(define (nap)
  (chez:sleep (make-time 'time-duration 1000000 0))
  'rested)

(define (chez-wind?) (eq? chez:dynamic-wind dynamic-wind))
