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

;; Not parameterize: its winders would put the port back at the pause,
;; before web's task writes.
(define (output-of thunk)
  (let ([out (current-output-port)])
    (let-values ([(o get) (open-string-output-port)])
      (current-output-port o)
      (thunk)
      (current-output-port out)
      (get))))

(test "a port set to the one web listens on keeps its listener, and #f moves web back to a free port"
  (let ([p (web-test/http:url-port (web:url))])
    (check-equal? "" (output-of (lambda () (options:set! web:port p) (web-test/tasks:settle))))
    (check-equal? (format "http://127.0.0.1:~a/" p) (web:url))
    (let ([said (output-of (lambda () (options:set! web:port #f) (web-test/tasks:settle)))])
      (check-equal? (format "Tuna is at ~a\n" (web:url)) said))
    (check (>= (web-test/http:url-port (web:url)) 7337))))
