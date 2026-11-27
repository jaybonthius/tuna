#!tuna
(import (saved))
(saved:define-saved x 0 (lambda (v) (or (eqv? v 0) (let loop () (loop)))))
