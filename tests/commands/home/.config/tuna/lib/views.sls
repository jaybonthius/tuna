#!tuna
;; Stands in for the views plugin, which this configuration lacks.
(define %shown #f)
(define %position 1)

(define (show! buffer)
  (set! %shown buffer)
  (set! %position 1))

(define (current) 'the-view)
(define (buffer view) %shown)
(define (point view) %position)
(define (set-point! view p) (set! %position p))
