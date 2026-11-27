(import (tuna) (test) (test-runner) (web) (options) (web-test http))

(define first-url (call-with-input-file (string-append (getenv "HOME") "/first-url") read))

(test-runner:wait-for-batch)

(test "the default port passes over a port another Tuna listens on"
  (check (string? (web:url)))
  (check (not (equal? first-url (web:url)))))

(test "a set port in use is reported, and web listens nowhere until the port is set again"
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (options:set! web:port (web-test/http:url-port first-url))
    (test-runner:wait-for-batch)
    (advice-remove! report keep)
    (check-equal? 1 (length reported))
    (check-equal? (list "127.0.0.1" (web-test/http:url-port first-url)) (list-head (condition-irritants (car reported)) 2))
    (check-equal? #f (web:url))
    (options:set! web:port #f)
    (test-runner:wait-for-batch)
    (check (string? (web:url)))))
