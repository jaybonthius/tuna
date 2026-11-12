#!tuna
;; Stands in for commands, so that the stand-in editing's paste runs
;; without a command definition.
(define (run command . arguments)
  (apply command arguments))
