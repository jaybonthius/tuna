(import (tuna) (tuna eval) (good))

;; Chez judges a source changed by its modification time, so a file
;; written in the clock tick its object was compiled in would count as
;; unchanged.
(define (write-module! path text)
  (sleep-for 0.01)
  (call-with-output-file path (lambda (p) (put-string p text)) 'replace))
(import (console))
