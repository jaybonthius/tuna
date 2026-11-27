#!tuna
;; A file, since what is noted while Tuna exits must outlive the process.
(define (note! text)
  (call-with-output-file (string-append (getenv "HOME") "/events")
    (lambda (p) (put-string p text) (newline p))
    'append))

;; Each report is noted as data rather than written, so the test knows
;; every report the exit made, and standard error holds only the rest.
(advice-add! report
  (lambda (next c)
    (note! (cond
             [(cancelled? c) "reported &cancelled"]
             [(and (condition? c) (who-condition? c)) (format "reported ~a" (condition-who c))]
             [else "reported"]))))
