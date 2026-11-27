(import (tuna) (test) (web) (options))

(define (settle)
  (suspend (lambda (resume) (spawn-task (lambda (restore) (resume void))))))

(define (url-port url)
  (string->number (substring url (string-length "http://127.0.0.1:") (- (string-length url) 1))))

(define first-url (call-with-input-file (string-append (getenv "HOME") "/first-url") read))

(settle)

(test "the default port passes over a port another Tuna listens on"
  (check (string? (web:url)))
  (check (not (equal? first-url (web:url)))))

(test "a set port in use is reported, and web listens nowhere until the port is set again"
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (options:set! web:port (url-port first-url))
    (settle)
    (advice-remove! report keep)
    (check-equal? 1 (length reported))
    (check-equal? (list "127.0.0.1" (url-port first-url)) (list-head (condition-irritants (car reported)) 2))
    (check-equal? #f (web:url))
    (options:set! web:port #f)
    (settle)
    (check (string? (web:url)))))
