#!tuna
(define m (make-mutex))
(define evaluated 0)
(define log '())

(define (note! e) (set! log (cons e log)))

(define (guarded thunk)
  (with-mutex (begin (set! evaluated (+ evaluated 1)) m)
    (thunk)))

(define (wound thunk)
  (dynamic-wind
    (lambda () (note! 'in))
    thunk
    (lambda () (note! 'out))))

(define (free?)
  (and (mutex-acquire m #f)
       (begin (mutex-release m) #t)))
