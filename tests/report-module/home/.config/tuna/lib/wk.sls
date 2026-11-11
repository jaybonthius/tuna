#!tuna
(import (tuna workers))
(define-worker (fails x) (car x))
(define (go) (start-job fails 1 void))
