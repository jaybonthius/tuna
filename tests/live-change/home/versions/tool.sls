#!tuna
(define (advise! module name proc)
  ((eval-in-module `(lambda (p) (advice-add! ,name p)) module) proc))

(define (run module name proc)
  (as-module (this-module) (advise! module name proc)))
