#!tuna
(import (magit git))
(define (status) (magit/git:run))
(define (load-later!) (invoke-library '(magit later)))
(define (load-extra!) (invoke-library '(magit extra)))
