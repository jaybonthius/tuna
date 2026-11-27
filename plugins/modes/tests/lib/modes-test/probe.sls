#!tuna
(import (modes) (ask))

(define %changes '())

(define (take-changes!) (let ([c (reverse %changes)]) (set! %changes '()) c))

(modes:define-minor-mode counted-mode
  "Whether each change of the mode is counted."
  (on-change (lambda (on?) (set! %changes (cons on? %changes)))))

(modes:define-minor-mode talking-mode
  "Whether the mode says so when it changes."
  (on-change (lambda (on?) (ask:message (format "talking-mode is ~a" (if on? "on" "off"))))))
