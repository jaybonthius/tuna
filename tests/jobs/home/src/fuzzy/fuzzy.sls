#!tuna
(import (jobs))

(jobs:define-worker (match-names query emit)
  (import (fuzzy match))
  (emit (score query)))
