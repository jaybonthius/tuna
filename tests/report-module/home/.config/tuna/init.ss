(import (tuna) (tuna eval) (wk) (good))

(define (wait-for-end job module)
  (let loop ()
    (when (exists (lambda (change) (eq? (cadr change) job)) (module-changes module))
      (sleep-for 0.01)
      (loop))))

;; Chez judges a source changed by its modification time, so a file
;; written in the clock tick its object was compiled in would count as
;; unchanged.
(define (write-module! path text)
  (sleep-for 0.01)
  (call-with-output-file path (lambda (p) (put-string p text)) 'replace))
