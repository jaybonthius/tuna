#!tuna
(import (embark) (consult))
(define (version) "newest")
(define (export-action) (embark:act))
(set-option! embark:integrated #t)
