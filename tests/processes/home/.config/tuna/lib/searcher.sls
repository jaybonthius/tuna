#!tuna
(import (processes))

(define (search on-output on-exit)
  (as-module (this-module)
    (processes:start "sh" '("-c" "echo first; sleep 5; echo never") on-output on-exit)))
