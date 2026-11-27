#!tuna
(import (commands))

(define %browsed 0)

(define (browsed) %browsed)

(commands:define-command (browse-remote)
  "Opens the current file's page on its forge."
  (set! %browsed (+ %browsed 1)))
