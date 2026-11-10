#!tuna
(import (embark) (consult))
(define (version) "1c2d3e4")
(define (export-action) (embark:act))
(set-option! embark:integrated #t)
