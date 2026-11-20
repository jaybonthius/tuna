#!tuna
;; Stands in for the layout plugin, which this configuration lacks: a
;; frame is a client of the stand-in web plugin, since keys takes a client.
(import (commands) (keys) (web))

(define frames (list (web:make-client 1) (web:make-client 2)))

(define (current-frame) (car frames))

(define (other-frame) (cadr frames))

(define switches 0)

(commands:define-command (other-view)
  "Selects the next view."
  (set! switches (+ switches 1)))

(keys:bind! keys:global "C-x o" other-view)
