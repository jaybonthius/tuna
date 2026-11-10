#!tuna
(define x (suspend (lambda (resume) (resume (lambda () 1)))))
