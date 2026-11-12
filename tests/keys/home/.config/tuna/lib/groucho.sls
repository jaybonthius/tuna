#!tuna
(import (commands))

(define browsed 0)

(commands:define-command (browse-remote)
  "Opens the current file's page on its forge."
  (set! browsed (+ browsed 1)))
