(import (tuna) (timers))

(define (record! name datum)
  (call-with-output-file (string-append (getenv "HOME") "/" name) (lambda (p) (write datum p) (newline p)) 'append))

;; Reports are kept as data in the home, so the test reads what the console
;; reported, and standard error stays empty.
(advice-add! report
  (lambda (next c)
    (record! "reports" (if (and (who-condition? c) (message-condition? c))
                           (list (condition-who c) (condition-message c)
                                 (map (lambda (x) (if (or (number? x) (string? x) (symbol? x)) x 'other))
                                      (if (irritants-condition? c) (condition-irritants c) '())))
                           'other))))

(on-unload (lambda () (record! "unloaded" 'configuration)))

(putprop 'console-test 'phase 'paused)
(import (console))
(timers:sleep 0.5)
(putprop 'console-test 'phase 'resumed)
