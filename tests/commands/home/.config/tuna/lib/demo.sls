#!tuna
(import (commands))

(define order '())

(define (note! x)
  (set! order (cons x order))
  x)

(commands:define-command (hello [name "you"])
  "Says hello to NAME."
  (string-append "Hello, " name "!"))

(commands:define-command (add a b)
  "Adds A and B."
  (+ a b))

(commands:define-command (ordered [a (note! 'a)] [b (note! 'b)] [c (note! 'c)])
  "Returns its arguments, read in order."
  (list a b c))

(commands:define-command (slow [x (begin (sleep-for 0.01) 'slept)])
  "Reads its argument after a pause."
  x)

(commands:define-command (which-task [t (current-task)])
  "Returns the task its argument was read in."
  t)
