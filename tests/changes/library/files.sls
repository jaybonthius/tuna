#!tuna
(define-record-type entry (fields path))

(define (save! path)
  "Saves the file at a path."
  path)
