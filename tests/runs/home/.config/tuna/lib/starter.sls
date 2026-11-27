#!tuna
(import (runs) (processes))

(define %self (current-owner))

;; The REPL calls these as (repl), so each names its own module as the
;; owner, as a plugin's command does.
(define (own!)
  (call-as-owner %self (lambda () (runs:start "*own*" "echo own; sleep 30" (processes:options [directory "~/"])))))

(define (users!)
  (call-as-owner %self (lambda () (runs:start-for-user "*users*" "echo users; until [ -e go ]; do sleep 0.05; done; echo later" (processes:options [directory "~/"])))))
