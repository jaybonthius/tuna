#!tuna
(import (saved))
;; The property says the check has begun, so the test cancels inside it.
(saved:define-saved x 0
  (lambda (v) (or (eqv? v 0) (begin (putprop 'saved-test 'checking #t) (let loop () (loop))))))
