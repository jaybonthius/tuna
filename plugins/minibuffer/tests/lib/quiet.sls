#!tuna
;; Imported before echo-area, so its advice sits beneath echo-area's,
;; which still sees each report while this keeps it from standard error.
(define %on? (box #f))

(define (silence! on?) (set-box! %on? on?))

(advice-add! report (lambda (next c) (unless (unbox %on?) (next c))))
