#!tuna
(import (rename (only (chezscheme) sleep) (sleep chez:sleep)))

;; Chez finds a module stale when its source is newer than its object, and
;; file times step with the kernel's clock tick, 1 to 10 ms, so a rewrite
;; in the tick of the last compile would look unchanged.
(define (write-module! name text)
  (suspend (lambda (resume) (fork-task (lambda (restore) (chez:sleep (make-time 'time-duration 10000000 0)) (resume void)))))
  (call-with-output-file (string-append (getenv "HOME") "/.config/tuna/lib/" name ".sls")
    (lambda (p) (put-string p text))
    'replace))
