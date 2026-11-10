#!tuna
(define-table all)
(define-syntax define-command
  (syntax-rules ()
    [(_ (name . formals) body ...)
     (begin
       (define-public (name . formals) body ...)
       (define-values () (begin (table-set! all 'name name) (values))))]))
