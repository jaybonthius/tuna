(import (tuna) (timers) (processes))

(define on-terminal (processes:start-for-user "sleep" '("30") (processes:options [terminal '(24 . 80)])))
(define on-pipes (processes:start-for-user "sleep" '("30")))
(define own (processes:start "sleep" '("30") (lambda (bytes end) (void))))

(let wait ([tries 3000])
  (unless (or (zero? tries) (for-all processes:pid (list on-terminal on-pipes own)))
    (timers:sleep 0.01)
    (wait (- tries 1))))

(call-with-output-file (string-append (getenv "HOME") "/pids")
  (lambda (p) (write (map processes:pid (list on-terminal on-pipes own)) p)))

(exit)
