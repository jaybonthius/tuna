(import (tuna) (test) (test-runner) (web) (haml) (options) (web-test http))

(web-test/http:use-url! (lambda () (web:url)))
(test-runner:wait-until (lambda () (web:url)))

;; A port from free-port stays bound by this process and is outside the
;; range a default port takes, so no other Tuna takes it while web is
;; away.
(define port (web-test/http:free-port))
(options:set! web:port port)
(test-runner:wait-until (lambda () (equal? (web:url) (format "http://127.0.0.1:~a/" port))))

(define p (web-test/http:page))
(web-test/http:connect! p)

(test "reloading web stops its server and starts another on the same port"
  (check-equal? 1 (length (web:clients)))
  (reload-modules! '((web)))
  (test-runner:wait-until (lambda () (web:url)))
  (check-equal? (format "http://127.0.0.1:~a/" port) (web:url)))

(test "a page from before finds no client, reloads and becomes a new client"
  (check-equal? 'closed (web-test/http:next p))
  (check-equal? '() (web:clients))
  (let ([first (web-test/http:connect-and-next! p)])
    (check-equal? '((script "location.reload()") closed) (list first (web-test/http:next p))))
  (let ([q (web-test/http:page)])
    (web-test/http:connect! q)
    (check-equal? 1 (length (web:clients)))
    (web:send-screen! (car (web:clients)) (haml (:p "new")) "Tuna")
    (check-equal? '(screen 1 0 ((p "new"))) (web-test/http:next q))
    (set! p q)))

(test "unloading web stops its server"
  (unload-owner! (module-owner '(web)))
  (check-equal? 'closed (web-test/http:next p))
  (check-equal? "cannot connect"
    (guard (e [(error? e) (condition-message e)]) (web-test/http:on-port port (lambda () (web-test/http:get "/"))) 'connected)))
