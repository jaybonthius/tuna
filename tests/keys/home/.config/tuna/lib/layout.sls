#!tuna
;; Stands in for the layout plugin, which this configuration lacks: a
;; frame is a record keys does not look inside.
(import (commands) (keys))

(define-record-type frame (fields name))

(define frames (list (make-frame "first") (make-frame "second")))

(define (current-frame) (car frames))

(define (other-frame) (cadr frames))

(define switches 0)

(commands:define-command (other-view)
  "Selects the next view."
  (set! switches (+ switches 1)))

(keys:bind! keys:global "C-x o" other-view)
