#!tuna
(import (magit git))
(define (status) (magit/git:run))
