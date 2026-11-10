#!tuna
(define-syntax define-command
  (syntax-rules () [(_ (n . f) b ...) (define-public (n . f) b ...)]))
(define-syntax define-point
  (syntax-rules () [(_ n) (define-record-type n (fields x))]))
(define-syntax def-const
  (syntax-rules () [(_ n v) (define n v)]))
(define-command (hello) "hello")
(define-point pt)
(def-const limit 10)
(define-public (greeting) "hi")
(define-record-type entry (fields key))
(define-values (low high) (values 1 9))
(define (origin) (list (pt-x (make-pt 0)) limit))
