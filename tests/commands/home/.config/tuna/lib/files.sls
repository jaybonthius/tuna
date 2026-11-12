#!tuna
;; Stands in for the files plugin, which this configuration lacks.
(import (commands))

(define visits '())

(commands:define-command (find-file [path "notes.txt"])
  "Visits the file at PATH."
  (set! visits (cons (list path (commands:prefix-argument)) visits)))
