#!tuna
(import (completion))

(define worker #f)

(define source (completion:source (job worker #f) (stream values)))
