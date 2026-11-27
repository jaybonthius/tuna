(import (tuna) (test) (test-runner) (web) (options) (web-test http))

(web-test/http:use-url! (lambda () (web:url)))
(test-runner:wait-until (lambda () (web:url)))

(define (port) (web-test/http:url-port (web:url)))

(define (at text) (format "~a:~a" text (port)))

(define (status . headers) (web-test/http:status (web-test/http:get "/web/tuna.js" headers)))

(define (refused thunk) (guard (e [(error? e) (condition-message e)]) (thunk) 'connected))

(define (listening-on? p) (equal? (format "http://127.0.0.1:~a/" p) (web:url)))

(test "a request whose Host is not 127.0.0.1 or localhost at the port, in any case, gets 403"
  (check-equal? '(200 200 200 403 403 403)
    (list (status) (status (cons "host" (at "localhost"))) (status (cons "host" (at "LOCALHOST")))
          (status '("host" . "evil.example")) (status (cons "host" (format "127.0.0.1:~a" (+ (port) 1))))
          (status '("host" . "127.0.0.1")))))

(test "a request whose Origin is not http:// or https:// and one of those hosts gets 403, null and input included"
  (check-equal? '(200 200 403 403 403)
    (list (status (cons "origin" (at "http://127.0.0.1"))) (status (cons "origin" (at "https://localhost")))
          (status '("origin" . "http://evil.example")) (status '("origin" . "null"))
          (status (cons "origin" (string-append (at "http://127.0.0.1") ".evil.example")))))
  (check-equal? 403 (web-test/http:status (web-test/http:post "/input" '(("origin" . "http://evil.example")) "{}"))))

(test "web:hosts names more hosts, such as one tailscale serve forwards, in any case, with their origins"
  (options:set! web:hosts '("tuna.example.ts.net"))
  (check-equal? '(200 200 200 403)
    (list (status '("host" . "tuna.example.ts.net")) (status '("host" . "Tuna.Example.ts.net"))
          (status '("host" . "tuna.example.ts.net") '("origin" . "https://tuna.example.ts.net"))
          (status '("host" . "other.ts.net"))))
  (check-equal? 200 (web-test/http:status (web-test/http:get "/" '(("host" . "tuna.example.ts.net")))))
  (options:unset! web:hosts)
  (check-equal? 403 (status '("host" . "tuna.example.ts.net"))))

(test "web:hosts takes a list of strings, and web:port a port or #f"
  (let ([refused-value? (lambda (c) (and (who-condition? c) (eq? 'options:set! (condition-who c))))])
    (check-raises refused-value? (options:set! web:hosts '(tuna)))
    (check-raises refused-value? (options:set! web:port 0))
    (check-raises refused-value? (options:set! web:port 65536))
    (check-raises refused-value? (options:set! web:port "7337"))))

(define (fetch path)
  (let ([r (web-test/http:get path)]) (list (web-test/http:status r) (web-test/http:header r "content-type"))))

(test "the page, Tuna's page module and Datastar are served, and nothing else; the page is never cached"
  (check-equal? '((200 "text/javascript; charset=utf-8") (200 "text/javascript; charset=utf-8") (200 "text/html; charset=utf-8")
                  (404 "text/plain") (404 "text/plain") (404 "text/plain") (404 "text/plain") (404 "text/plain"))
    (map fetch '("/web/tuna.js" "/web/datastar.js" "/" "/nothing" "/web/nothing.js" "/web/../web.sls" "/web/%2e%2e/web.sls"
                 "/files/1/x.css")))
  (check-equal? "no-store" (web-test/http:header (web-test/http:get "/") "cache-control")))

;; Ports from free-port stay bound by this process and are not in the
;; range a default port takes, so no other Tuna listens on one while the
;; test looks.
(test "setting the port moves the server once the running code ends, and the old port is listened on no more"
  (let ([first (web-test/http:free-port)] [second (web-test/http:free-port)])
    (options:set! web:port first)
    (test-runner:wait-until (lambda () (listening-on? first)))
    (options:set! web:port second)
    (check (listening-on? first))
    (test-runner:wait-until (lambda () (listening-on? second)))
    (check-equal? 200 (status))
    (check-equal? "cannot connect" (refused (lambda () (web-test/http:on-port first status))))))

(test "a port in use is reported, nothing is listened on, and the server starts when the port is set again"
  (let ([before (port)] [taken (web-test/http:free-port)] [next (web-test/http:free-port)])
    (web-test/http:occupy! taken)
    (let ([reported (test-runner:reports-during
                      (lambda ()
                        (options:set! web:port taken)
                        (test-runner:wait-until (lambda () (not (web:url))))
                        (test-runner:wait-for-batch)))])
      (check-equal? 1 (length reported))
      (check-equal? (list "127.0.0.1" taken) (list-head (condition-irritants (car reported)) 2)))
    (check-equal? "cannot connect" (refused (lambda () (web-test/http:on-port before status))))
    (options:set! web:port next)
    (test-runner:wait-until (lambda () (listening-on? next)))
    (check-equal? 200 (status))))
