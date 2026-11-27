#!tuna
;; An override keeps a report from standard error and from the test's
;; failure, while advice such as the echo area's still sees it.
(define (reports-during thunk)
  (let ([reported '()])
    (override-set! report (lambda (c) (set! reported (cons c reported))))
    (thunk)
    (override-remove! report)
    (reverse reported)))
