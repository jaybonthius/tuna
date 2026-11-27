#!tuna
(import (embark) (consult) (options))
(define (version) "newest")
(define (export-action) (embark:act))
(options:set! embark:integrated #t)
