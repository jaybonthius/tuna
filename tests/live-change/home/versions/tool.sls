#!tuna
(define %self (current-owner))
(define (advise! module name proc)
  ((eval-in-module `(lambda (p) (advice-add! ,name p)) module) proc))

(define (run module name proc)
  (call-as-owner %self (lambda () (advise! module name proc))))
