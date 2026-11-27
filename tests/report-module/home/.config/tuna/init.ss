(import (timers) (plugins))
(import (tuna) (good))

;; Chez judges a source changed by its modification time, so a file
;; written in the clock tick its object was compiled in would count as
;; unchanged.
(define (write-module! path text)
  (timers:sleep 0.01)
  (call-with-output-file path (lambda (p) (put-string p text)) 'replace))
(import (console))
