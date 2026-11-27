(import (tuna) (test) (test-runner) (web) (options) (web-test http) (web-test tasks))

;; The server starts in a task queued at the end of the batch web loads
;; in.
(web-test/tasks:settle)

(test "web:port is #f by default, and web listens on 7337 or a port above it, which web:url names"
  (check-equal? #f (web:port))
  (check (>= (web-test/http:url-port (web:url)) 7337))
  (check-equal? (format "http://127.0.0.1:~a/" (web-test/http:url-port (web:url))) (web:url)))

(test "a Tuna started while this one listens passes over its port, and a set port in use is reported"
  (let ([home (string-append (getenv "HOME") "/second")])
    (mkdir home)
    (call-with-output-file (string-append home "/first-url") (lambda (p) (write (web:url) p)))
    (let-values ([(status errors) (test-runner:run-file "port/second.ss" home)])
      (check-equal? 0 status)
      (check-equal? "" errors))))

(test "a set port is listened on exactly, and #f moves web back to a free port"
  (let ([p (web-test/http:url-port (web:url))])
    (options:set! web:port p)
    (web-test/tasks:settle)
    (check-equal? (format "http://127.0.0.1:~a/" p) (web:url))
    (options:set! web:port #f)
    (web-test/tasks:settle)
    (check (>= (web-test/http:url-port (web:url)) 7337))))
