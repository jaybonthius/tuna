#!tuna
(import (completion))

(define worker #f)

(define source (completion:source (candidates (vector)) (job worker #f)))
