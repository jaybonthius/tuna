#!tuna
;; Stands in for the file-picker plugin, which this configuration lacks.
(import (commands))

(define %visits '())

(define (visits) %visits)

(commands:define-command (find-file [path "notes.txt"])
  "Visits the file at PATH."
  (set! %visits (cons (list path (commands:prefix-argument)) %visits)))
