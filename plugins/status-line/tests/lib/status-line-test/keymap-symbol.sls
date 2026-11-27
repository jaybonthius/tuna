#!tuna
(import (status-line))

(define (show-a view) "a")

(status-line:define-segment bad (show show-a) (keymap 'keys))
