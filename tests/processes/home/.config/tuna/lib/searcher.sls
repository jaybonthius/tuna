#!tuna
(import (processes))

(define %self (current-owner))

(define (search on-output on-exit)
  (call-as-owner %self (lambda () (processes:start "sh" '("-c" "echo first; sleep 5; echo never") on-output on-exit))))
