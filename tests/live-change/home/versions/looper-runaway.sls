#!tuna
(import (testing))
(define (f) 2)
(testing:request-quit!)
(let loop () (loop))
