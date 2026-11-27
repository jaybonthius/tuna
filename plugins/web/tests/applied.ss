(import (tuna) (test) (test-runner) (web) (haml) (web-test http))

(web-test/http:use-url! (lambda () (web:url)))
(test-runner:wait-until (lambda () (web:url)))

(define p (web-test/http:page))
(web-test/http:connect! p)
(define c (car (web:clients)))

(define (waiter) (spawn-task (lambda (restore) (web:wait-for-applied c))))

(define (ended? task) (eq? 'done (task-state task)))

(test "web:wait-for-applied pauses the calling task until the page has confirmed the screen in flight and the one waiting behind it"
  (web:send-screen! c (haml (:p "one")) "Tuna")
  (check-equal? '(screen 1 0 ((p "one"))) (web-test/http:next p))
  (let ([w (waiter)])
    (web:send-screen! c (haml (:p "two")) "Tuna")
    (web-test/http:confirm! p 1)
    (check-equal? '(screen 2 0 ((p "two"))) (web-test/http:next p))
    (check-equal? 'paused (task-state w))
    (web-test/http:confirm! p 2)
    (test-runner:wait-until (lambda () (ended? w)))))

(test "with every screen applied, it returns at once"
  (web:wait-for-applied c))

(test "a page whose stream closes applies nothing until a later screen, so the wait ends"
  (web:send-screen! c (haml (:p "three")) "Tuna")
  (check-equal? '(screen 3 0 ((p "three"))) (web-test/http:next p))
  (let ([w (waiter)])
    (web-test/http:close! p)
    ;; Tuna learns that a stream has closed when it next writes to it.
    (test-runner:wait-until (lambda () (web:call-page! c "ping" 0) (ended? w)))))

(test "the wait ends when the client is removed"
  (web-test/http:connect! p)
  (web:send-screen! c (haml (:p "four")) "Tuna")
  (check-equal? '(screen 4 0 ((p "four"))) (cadr (web-test/http:take p 2)))
  (let ([w (waiter)])
    (check-equal? 204 (web-test/http:goodbye! p))
    (test-runner:wait-until (lambda () (ended? w)))))

(test "web:wait-for-applied takes a client"
  (check-raises (lambda (e) (and (who-condition? e) (eq? 'web:wait-for-applied (condition-who e)) (equal? "not a client" (condition-message e))))
    (web:wait-for-applied 'nobody)))
