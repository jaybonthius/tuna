#!tuna
(import (runs) (processes))

;; The REPL calls these as (repl), so each names its own module as the
;; owner, as a plugin's command does.
(define (own!)
  (as-module (this-module) (runs:start "*own*" "echo own; sleep 30" (processes:options [directory "~/"]))))

(define (users!)
  (as-module (this-module)
    (runs:start-for-user "*users*" "echo users; until [ -e go ]; do sleep 0.05; done; echo later" (processes:options [directory "~/"]))))
