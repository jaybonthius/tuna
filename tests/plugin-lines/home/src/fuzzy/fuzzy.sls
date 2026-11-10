#!tuna
(define-worker (match-names query)
  (import (fuzzy match))
  (emit (score query)))
