#!tuna
;; Stands in for a completion list with a keymap of its own.
(import (commands) (keys))

(define-table keymap "The completion list's keys.")

(define moves 0)

(commands:define-command (next) "Selects the next candidate." (set! moves (+ moves 1)))
