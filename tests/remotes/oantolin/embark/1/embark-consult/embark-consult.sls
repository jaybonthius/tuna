#!tuna
(import (embark) (consult) (options))
(define (version) "1c2d3e4")
(define (export-action) (embark:act))
(options:set! embark:integrated #t)
