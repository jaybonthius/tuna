(import (tuna) (test) (test-runner) (timers) (web) (jsonrpc) (json-rpc) (jsonrpc-test servers))

(define (reports-during thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (let ([result (thunk)])
      (advice-remove! report keep)
      (values result (reverse reported)))))

(test "the program's requests are answered by the request clause in a task of its own that may pause; a &json-rpc-error it raises is sent back"
  (let* ([asked '()]
         [answer (lambda (c method params)
                   (set! asked (cons method asked))
                   (timers:sleep 0.05)
                   (cond
                     [(string=? method "workspace/configuration") '#((("tabSize" . 4)))]
                     [(string=? method "refuse") (raise (make-json-rpc-error -32001 "no, thanks"))]
                     [else (car '())]))]
         [c (jsonrpc-test/servers:start "fake" (jsonrpc:handlers [request answer]))])
    (check-equal? '(("result" . #((("tabSize" . 4))))) (jsonrpc:request c "ask" '(("method" . "workspace/configuration"))))
    (check-equal? '(("error" . -32001) ("message" . "no, thanks")) (jsonrpc:request c "ask" '(("method" . "refuse"))))
    (let-values ([(answered reported) (reports-during (lambda () (jsonrpc:request c "ask" '(("method" . "crash")))))])
      (check-equal? '(("error" . -32603) ("message" . "() is not a pair")) answered)
      (check-equal? '(car) (map condition-who reported)))
    (check-equal? '("crash" "refuse" "workspace/configuration") asked)
    (jsonrpc:stop! c)))

(test "notifications reach the notification clause in the order sent"
  (let* ([notified '()] [c (jsonrpc-test/servers:start "fake" (jsonrpc:handlers [notification (lambda (c method params) (set! notified (cons method notified)))]))])
    (check-equal? "sent" (jsonrpc:request c "notify" '(("methods" . #("one" "two" "three")))))
    (check-equal? '("one" "two" "three") (reverse notified))
    (jsonrpc:stop! c)))

(test "without a request clause, a request from the program is answered method not found"
  (let ([plain (jsonrpc-test/servers:start "plain" (jsonrpc:handlers))])
    (check-equal? '(("error" . -32601) ("message" . "method not found: anything")) (jsonrpc:request plain "ask" '(("method" . "anything"))))
    (jsonrpc:stop! plain)))

(test "when the program ends, the exit clause gets its status, and each request still waiting, in a task or async, gets jsonrpc:&ended"
  (let*-values ([(exited) '()] [(errors) '()]
                [(ending record) (jsonrpc-test/servers:start! "ending" (jsonrpc:handlers [exit (lambda (c status) (set! exited (cons status exited)))]))])
    (jsonrpc:request-async ending "wait" '() (lambda (v) (set! errors (cons v errors)))
      (lambda (e) (set! errors (cons (list 'ended (jsonrpc:ended-status e)) errors))))
    (let ([waiting (spawn-task (lambda (restore) (jsonrpc-test/servers:raised (lambda () (jsonrpc:request ending "wait" '())))))])
      (jsonrpc-test/servers:wait-for-records record 2)
      (jsonrpc:request-async ending "exit" '(("status" . 3)) (lambda (v) (void)) (lambda (e) (void)))
      (check-equal? '(ended 3) (test-runner:join waiting)))
    (check-equal? '((ended 3)) errors)
    (check-equal? '(3) exited)
    (check (not (jsonrpc:running? ending)))
    (check-equal? '(ended 3) (jsonrpc-test/servers:raised (lambda () (jsonrpc:request ending "echo" '()))))
    (jsonrpc:notify ending "anything" '())
    (let ([after '()])
      (jsonrpc:request-async ending "echo" '() (lambda (v) (set! after v)) (lambda (e) (set! after (jsonrpc:ended-status e))))
      (test-runner:wait-until (lambda () (equal? after 3))))))

(test "jsonrpc:stop! ends the program, and its waiting requests get jsonrpc:&ended"
  (let-values ([(plain record) (jsonrpc-test/servers:start! "plain" (jsonrpc:handlers))])
    (let ([stopped (spawn-task (lambda (restore) (jsonrpc-test/servers:raised (lambda () (jsonrpc:request plain "wait" '())))))])
      (jsonrpc-test/servers:wait-for-records record 1)
      (jsonrpc:stop! plain)
      (check-equal? 'ended (car (test-runner:join stopped))))))
