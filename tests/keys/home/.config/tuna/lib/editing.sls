#!tuna
;; Stands in for the editing plugin, which this configuration lacks.
(import (commands) (keys))

(define typed '())

(commands:define-command (next-line [n (commands:prefix-number)])
  "Moves down N lines."
  (set! typed (cons (list 'next-line n) typed)))

(commands:define-command (forward-char [n (commands:prefix-number)])
  "Moves forward N characters."
  (set! typed (cons (list 'forward-char n (keys:shift-translated?)) typed)))

(commands:define-command (self-insert [n (commands:prefix-number)])
  "Inserts the character typed N times."
  (set! typed (cons (list 'self-insert (keys:typed-char) n) typed)))

(define (take!)
  (let ([t (reverse typed)])
    (set! typed '())
    t))

(keys:bind! keys:global "C-n" next-line)
(keys:bind! keys:global "C-f" forward-char)
(keys:bind! keys:global "<right>" forward-char)
(keys:bind! keys:global "<printing-char>" self-insert)
(keys:bind! keys:global "SPC" self-insert)
