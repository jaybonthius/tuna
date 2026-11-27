#!tuna
;; Loaded before layout, so layout's advice on batch-ended wraps this.
(define %batch 0)
(define %fail? #f)
(define %cancel? #f)

(define (batch) %batch)
(define (fail-next!) (set! %fail? #t))
(define (cancel-next!) (set! %cancel? #t))

(advice-add! batch-ended
  (lambda (ended)
    (ended)
    (when %fail? (set! %fail? #f) (car '()))
    (when %cancel? (set! %cancel? #f) (raise (make-cancelled 'quit)))
    (set! %batch (+ %batch 1))))
