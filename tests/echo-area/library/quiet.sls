#!tuna
;; The configuration loads it first, so the advice of every plugin loaded
;; after it runs outside it and still sees each report.
(define %on? (box #f))

(define (silence! on?) (set-box! %on? on?))

(advice-add! report (lambda (report c) (unless (unbox %on?) (report c))))
