#!tuna
(import (testing))
(define (f) 1)
(testing:request-quit!)
(let loop () (loop))
