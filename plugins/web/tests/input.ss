(import (tuna) (test) (test-runner) (web) (hooks) (tables) (timers) (web-test http) (web-test tasks) (web-test handlers))

(web-test/http:use-url! (lambda () (web:url)))
(test-runner:wait-until (lambda () (web:url)))

(define log '())
(define (note! x) (set! log (cons x log)))
(define (taken!) (let ([l (reverse log)]) (set! log '()) l))

(define p (web-test/http:page))

(tables:set! web:input-handlers "note" (lambda (client item) (note! (cdr (assoc "n" item)))))

(test "items run in the order their client numbered them, whatever order they arrive in, and a number seen before is ignored"
  (check-equal? '(204 204 204 204 204 204 204)
    (web-test/http:send-numbered-all! p
      (map (lambda (seq) (list seq (cons "type" "note") (cons "n" seq))) '(3 1 2 2 5 4 1))))
  (check-equal? '(1 2 3 4 5) (taken!)))

(test "an item waits for every earlier item of its client"
  (check-equal? 204 (web-test/http:send-numbered! p 7 '(("type" . "note") ("n" . 7))))
  (web-test/tasks:settle)
  (check-equal? '() (taken!))
  (check-equal? 204 (web-test/http:send-numbered! p 6 '(("type" . "note") ("n" . 6))))
  (check-equal? '(6 7) (taken!)))

(test "every post that passes the checks gets 204, whatever it holds, and an item without a client or a number from 1 runs nowhere"
  (check-equal? '(204 204 204 204)
    (map (lambda (body) (web-test/http:status (web-test/http:post "/input" '() body)))
         '("not json" "[1, 2]" "{\"client\": \"nobody\", \"seq\": 1}" "{\"seq\": 1}")))
  (check-equal? 204 (web-test/http:send-numbered! p 0 '(("type" . "note") ("n" . 0))))
  (check-equal? 204 (web-test/http:send-numbered! p 8.0 '(("type" . "note") ("n" . 8.0))))
  (web-test/tasks:settle)
  (check-equal? '() (taken!)))

(test "a handler gets the client and the item, its client's id and number included"
  (tables:set! web:input-handlers "echo" (lambda (client item) (note! (list client item))))
  (check-equal? 204 (web-test/http:send-numbered! p 8 '(("type" . "echo") ("text" . "hi"))))
  (let ([seen (car (taken!))])
    (check (web:client? (car seen)))
    (check-equal? (list '("type" . "echo") '("text" . "hi") (cons "client" (web-test/http:id p)) '("seq" . 8)) (cadr seen))))

(test "a handler runs as the owner whose entry is in effect: a test file's, or a module's"
  (tables:set! web:input-handlers "owner" (lambda (client item) (note! (current-owner))))
  (web-test/http:send! p '(("type" . "owner")))
  (check-equal? (list (current-owner)) (taken!))
  (web-test/http:send! p '(("type" . "module-owner")))
  (check-equal? (module-owner '(web-test handlers)) (web-test/handlers:owner)))

(test "a handler that raises is reported as its module's, and the next item runs"
  (let ([reported (web-test/tasks:reports-during
                    (lambda ()
                      (check-equal? '(204 204)
                        (web-test/http:send-all! p '((("type" . "module-fail")) (("type" . "note") ("n" . "next")))))))])
    (check-equal? 1 (length reported))
    (check-equal? '(car "~s is not a pair") (list (condition-who (car reported)) (condition-message (car reported)))))
  (check-equal? '("next") (taken!)))

(test "an item whose type has no handler is skipped, with one report per type"
  (let ([reported (web-test/tasks:reports-during
                    (lambda ()
                      (check-equal? '(204 204 204 204)
                        (web-test/http:send-all! p
                          '((("type" . "nothing")) (("type" . "nothing")) (("n" . 1)) (("type" . "note") ("n" . "after")))))))])
    (check-equal? '((web:input-handlers "no handler for items of type \"nothing\"") (web:input-handlers "no handler for items of type #f"))
                  (map (lambda (c) (list (condition-who c) (condition-message c))) reported))
    (check (for-all warning? reported)))
  (check-equal? '("after") (taken!)))

(define spinning #f)

;; The spinning item holds the main thread, so the quits are sent from a
;; thread of its own once it spins, as a page's would come.
(define (send-while-spinning! type quits)
  (set! spinning #f)
  (test-runner:join
    (fork-task
      (lambda (restore)
        (let ([first (web-test/http:send! p (list (cons "type" type)))])
          (test-runner:wait-until (lambda () spinning))
          (cons first (map (lambda (quit) (web-test/http:send! p quit)) quits)))))))

(define quit-item '(("type" . "keyboard-quit") ("quit" . #t)))

(tables:set! web:input-handlers "keyboard-quit" (lambda (client item) (note! 'quit-ran)))

(test "an item whose quit is true cancels the command running when it arrives, then runs in its turn"
  (tables:set! web:input-handlers "spin" (lambda (client item) (set! spinning #t) (let loop () (loop))))
  (let ([reported (web-test/tasks:reports-during
                    (lambda () (check-equal? '(204 204) (send-while-spinning! "spin" (list quit-item)))))])
    (check-equal? '(#t) (map cancelled? reported))
    (check-equal? '(quit) (map cancelled-reason reported)))
  (check-equal? '(quit-ran) (taken!)))

(test "a command that holds cancels off is stopped by the second quit, as the first waits behind it"
  (let ([spun #f])
    (tables:set! web:input-handlers "masked-spin"
      (lambda (client item)
        (set! spun (current-task))
        (call-with-cancellation-masked (lambda (restore) (set! spinning #t) (let loop () (loop))))))
    (check-equal? '(204 204 204) (send-while-spinning! "masked-spin" (list quit-item quit-item)))
    (web-test/tasks:settle)
    (check-equal? 'stopped (let-values ([(how detail) (join-task spun)]) how))
    (check-equal? '(quit-ran quit-ran) (taken!))
    (check-equal? 204 (web-test/http:send! p quit-item))
    (web-test/tasks:settle)
    (check-equal? '(quit-ran) (taken!))))

(test "a quit item seen before, as when a page resends one whose post failed, quits nothing"
  (tables:set! web:input-handlers "spin-briefly"
    (lambda (client item)
      (let ([end (+ (real-time) 500)])
        (let loop () (when (< (real-time) end) (loop))))
      (note! 'spun)))
  (let ([resender (web-test/http:page)])
    (check-equal? 204 (web-test/http:send! resender quit-item))
    (check-equal? '(204 204)
      (web-test/http:send-numbered-all! resender (list (cons 2 '(("type" . "spin-briefly"))) (cons 1 quit-item))))
    (web-test/tasks:settle)
    (check-equal? '(quit-ran spun) (taken!))))

(define answer #f)

(test "each item runs as a task of its own, so one that pauses lets the next run, and Tuna is idle while it is paused"
  (tables:set! web:input-handlers "ask" (lambda (client item) (note! (suspend (lambda (resume) (set! answer resume))))))
  (check-equal? '(204 204) (web-test/http:send-all! p '((("type" . "ask")) (("type" . "note") ("n" . "typed")))))
  (check-equal? '("typed") (taken!))
  (check (real? (timers:idle-seconds)))
  (answer (lambda () "answered"))
  (web-test/tasks:settle)
  (check-equal? '("answered") (taken!)))

(test "while an item runs, web:current-client is its client, also after the item pauses, and #f outside an item"
  (tables:set! web:input-handlers "whose"
    (lambda (client item)
      (note! (eq? (web:current-client) client))
      (note! (eq? (suspend (lambda (resume) (set! answer resume))) (void)))
      (note! (eq? (web:current-client) client))))
  (web-test/http:send! p '(("type" . "whose")))
  (check-equal? '(#t) (taken!))
  (answer void)
  (web-test/tasks:settle)
  (check-equal? '(#t #t) (taken!))
  (check-equal? #f (web:current-client))
  (check-raises (lambda (e) (and (who-condition? e) (eq? 'web:current-client (condition-who e)))) (web:current-client 'nobody)))

(test "Tuna is not idle while an item runs, and is idle once none waits"
  (tables:set! web:input-handlers "idle" (lambda (client item) (note! (timers:idle-seconds))))
  (web-test/http:send! p '(("type" . "idle")))
  (check-equal? '(#f) (taken!))
  (check (real? (timers:idle-seconds))))

(test "a client holding 10,000 items behind a missing one is removed, and its page reloads"
  (let ([removed '()] [q (web-test/http:page)])
    (define (note-removed client) (set! removed (cons client removed)))
    (hooks:add! web:client-removed note-removed)
    (web-test/http:connect! q)
    (let ([client (find (lambda (c) (not (memq c removed))) (reverse (web:clients)))])
      (check-equal? 10000 (web-test/http:send-range! q 2 10001 '(("type" . "note"))))
      (check-equal? '((script "location.reload()") closed) (web-test/http:take q 2))
      (web-test/tasks:settle)
      (check-equal? (list client) removed))
    (check-equal? 204 (web-test/http:send-numbered! q 1 '(("type" . "note") ("n" . 1))))
    (web-test/tasks:settle)
    (check-equal? '() (taken!))
    (hooks:remove! web:client-removed note-removed)))
