#!tuna
(define-option fetch-fn #f (lambda (v) (or (not v) (procedure? v))))
