(import (tuna) (test) (test-runner) (web) (haml) (tables) (timers) (web-test http))

(web-test/http:use-url! (lambda () (web:url)))
(test-runner:wait-until (lambda () (web:url)))

(define (raised-by who message)
  (lambda (c) (and (who-condition? c) (eq? who (condition-who c)) (equal? message (condition-message c)))))

(define p (web-test/http:page))

(test "a client is connected while its stream is open"
  (check-equal? '() (web:clients))
  (web-test/http:connect! p)
  (check-equal? 1 (length (web:clients))))

(define c (car (web:clients)))

(define (next) (web-test/http:next p))

(define (nothing-sent?) (eq? 'timeout (web-test/http:next p 0.2)))

(test "a screen goes to the page as given, and a screen whose bytes equal the last one given does not"
  (web:send-screen! c (haml (:p "one")) "Tuna")
  (check-equal? '(screen 1 0 ((p "one"))) (next))
  (web:send-screen! c (string->utf8 "<p>one</p>") "Tuna")
  (check (nothing-sent?)))

(test "one screen is in flight: one given meanwhile waits, replacing any already waiting, and goes when the page confirms"
  (web:send-screen! c (haml (:p "two")) "Tuna")
  (web:send-screen! c (haml (:p "three")) "Tuna")
  (check (nothing-sent?))
  (check-equal? 204 (web-test/http:confirm! p 1))
  (check-equal? '(screen 2 0 ((p "three"))) (next)))

(test "a confirmation of another screen than the one in flight lets nothing go"
  (check-equal? 204 (web-test/http:confirm! p 1))
  (web:send-screen! c (haml (:p "four")) "Tuna")
  (check (nothing-sent?)))

;; The rule is about time: a page that has not confirmed within a second
;; is sent the next screen anyway.
(test "a screen given when the one in flight was sent over a second before goes at once"
  (timers:sleep 1.1)
  (web:send-screen! c (haml (:p "five")) "Tuna")
  (check-equal? '(screen 3 0 ((p "five"))) (next)))

(test "a call goes after the screens already given to the client"
  (web-test/http:confirm! p 3)
  (web:send-screen! c (haml (:p "six")) "Tuna")
  (web:send-screen! c (haml (:p "seven")) "Tuna")
  (web:call-page! c "copy" "text")
  (check-equal? '(screen 4 0 ((p "six"))) (next))
  (check (nothing-sent?))
  (web-test/http:confirm! p 4)
  (check-equal? '((screen 5 0 ((p "seven"))) (script "tuna.call(\"copy\", \"text\")")) (web-test/http:take p 2))
  (web-test/http:confirm! p 5))

(test "a call's value goes as JSON that cannot end the page's script"
  (web:call-page! c "show-value" '(("a" . "</script>") ("b" . #(1 2.5 #t null))))
  (check-equal? '(script "tuna.call(\"show-value\", {\"a\":\"\\u003c/script\\u003e\",\"b\":[1,2.5,true,null]})") (next)))

(test "a screen records the last item of its client that ran before it"
  (tables:set! web:input-handlers "draw" (lambda (client item) (web:send-screen! client (haml (:p "drawn")) "Tuna")))
  (tables:set! web:input-handlers "noop" (lambda (client item) (void)))
  (check-equal? 204 (web-test/http:send-numbered! p 2 '(("type" . "draw"))))
  (check-equal? 204 (web-test/http:send-numbered! p 1 '(("type" . "noop"))))
  (check-equal? '(screen 6 2 ((p "drawn"))) (next))
  (web-test/http:confirm! p 6)
  (tables:remove! web:input-handlers "draw")
  (tables:remove! web:input-handlers "noop"))

(test "web:send-screen! and web:call-page! check their arguments; a name of 64 letters, digits and hyphens is a name"
  (check-raises (raised-by 'web:send-screen! "not a client") (web:send-screen! 'nobody (haml (:p "x")) "Tuna"))
  (check-raises (raised-by 'web:send-screen! "not html or a bytevector") (web:send-screen! c "<p>x</p>" "Tuna"))
  (check-raises (raised-by 'web:call-page! "not a client") (web:call-page! 'nobody "copy" 1))
  (for-each
    (lambda (name)
      (check-raises (raised-by 'web:call-page! "not 1 to 64 letters, digits and hyphens") (web:call-page! c name 1)))
    (list "copy text" "" (make-string 65 #\a)))
  (check-raises (raised-by 'web:call-page! "(json) cannot write it") (web:call-page! c "copy" car))
  (web:call-page! c (make-string 64 #\a) 1)
  (check-equal? (list 'script (format "tuna.call(~s, 1)" (make-string 64 #\a))) (next)))

(test "a screen larger than the stream can hold is not sent and is reported, and the page keeps its last"
  (let ([reported (test-runner:reports-during
                    (lambda () (web:send-screen! c (make-bytevector (* 5 1024 1024) (char->integer #\x)) "Tuna") (test-runner:wait-for-batch))
                    1)])
    (check-equal? 1 (length reported))
    (check (warning? (car reported)))
    (check-equal? "a screen is larger than the stream's limit, so the page keeps the last" (condition-message (car reported))))
  (check (nothing-sent?)))

(define (x-screen mebibytes) (make-bytevector (* mebibytes 1024 1024) (char->integer #\x)))

;; The rule is about time too: the second screen would go at once were
;; the first sent under a second before.
(test "a screen waits for the page to confirm the last while the screens it has not confirmed and the new one would pass what the stream holds"
  (web:send-screen! c (x-screen 3) "Tuna")
  (check-equal? '(screen 7 2) (list-head (next) 3))
  (timers:sleep 1.1)
  (web:send-screen! c (x-screen 2) "Tuna")
  (check (nothing-sent?))
  (web-test/http:confirm! p 7)
  (check-equal? '(screen 8 2) (list-head (next) 3))
  (web-test/http:confirm! p 8))

(test "a question to the page goes after the screen of its batch, and the page's answer, on its own route, resumes the asking task"
  (let ([asker (spawn-task (lambda (restore) (web:ask-page c "size" 5)))])
    (test-runner:wait-for-batch)
    (web:send-screen! c (haml (:p "asked")) "Tuna")
    (check-equal? '((screen 9 2 ((p "asked"))) (script "tuna.ask(1, \"size\", 5)")) (web-test/http:take p 2))
    (check-equal? 204
      (web-test/http:status
        (web-test/http:post "/answer" '()
          (format "{\"client\":\"~a\",\"id\":1,\"value\":{\"rows\":24}}" (web-test/http:id p)))))
    (test-runner:wait-until (lambda () (eq? 'done (task-state asker))))
    (check-equal? '(returned ((("rows" . 24)))) (let-values ([(how detail) (join-task asker)]) (list how detail))))
  (web-test/http:confirm! p 9))

(test "a client whose stream has closed is not connected, gets neither screens nor calls, and its questions are answered #f"
  (web-test/http:close! p)
  ;; Tuna learns that a stream has closed when it next writes to it.
  (test-runner:wait-until (lambda () (web:call-page! c "ping" 0) (null? (web:clients))))
  (web:send-screen! c (haml (:p "unseen")) "Tuna")
  (web:call-page! c "copy" "unseen")
  (check-equal? #f (web:ask-page c "size" 1))
  (check-equal? '() (web:clients)))

(define (drawing ended)
  (ended)
  (for-each (lambda (client) (web:send-screen! client (haml (:p "drawn")) "Tuna")) (web:clients)))

(test "when a client's stream opens again, the next screen and title are sent though unchanged, and a batch ends, so a display that draws after each batch sends them"
  (advice-add! batch-ended drawing)
  (let ([title (web-test/http:connect-and-next! p)])
    (check-equal? '(patch #f #f) (list-head title 3))
    (check-equal? '("Tuna") (map web-test/http:element-text (web-test/http:elements-named (cadddr title) 'title))))
  (check-equal? '(screen 10 2 ((p "drawn"))) (next))
  (check (nothing-sent?))
  (advice-remove! batch-ended drawing))
