(import (tuna) (test) (test-runner) (web) (processes) (jsonrpc) (json-rpc) (servers))

(define (message thunk)
  (guard (c [(assertion-violation? c) (condition-message c)]) (thunk) 'no-violation))

(define cancels '())

(define (note-cancel! c id) (set! cancels (cons id cancels)))

(define-values (c c-record) (servers:start! "fake" (jsonrpc:handlers [cancel note-cancel!])))

;; Cancelling a waiting task makes the kernel report the cancel.
(define (cancel-waiting! task)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (cancel-task task)
    (test-runner:wait-until (lambda () (eq? (task-state task) 'done)))
    (test-runner:wait-until (lambda () (pair? reported)))
    (advice-remove! report keep)
    (check (for-all cancelled? reported))))

(test "a request pauses its task until the program answers, and returns the result"
  (check-equal? '(("a" . 1)) (jsonrpc:request c "echo" '(("a" . 1))))
  (check-equal? '#(1 "two" #t null) (jsonrpc:request c "echo" '#(1 "two" #t null)))
  (check (jsonrpc:connection? c))
  (check (not (jsonrpc:connection? 'c)))
  (check (jsonrpc:running? c))
  (check-equal? "fake" (jsonrpc:connection-name c))
  (check (processes:process? (jsonrpc:connection-process c))))

(test "an error the program answers is its own &json-rpc-error with code, message and data, -32099 included"
  (check-equal? '(json-rpc-error -32602 "bad params")
    (servers:raised (lambda () (jsonrpc:request c "fail" '(("code" . -32602) ("message" . "bad params"))))))
  (check-equal? '(json-rpc-error -32099 "server busy")
    (servers:raised (lambda () (jsonrpc:request c "fail" '(("code" . -32099) ("message" . "server busy"))))))
  (check-equal? '#(1 2)
    (guard (e [(json-rpc-error? e) (json-rpc-error-data e)])
      (jsonrpc:request c "fail" '(("code" . 1) ("message" . "m") ("data" . #(1 2)))))))

(test "a request the program never answers raises jsonrpc:&timeout after its time, naming the method"
  (check-equal? '(timeout "wait") (servers:raised (lambda () (jsonrpc:request c "wait" '() 0.1))))
  (check-equal? 10 (jsonrpc:request-timeout)))

(test "a cancel of a waiting task calls the cancel clause with the request's id, and the answer, when it comes, is dropped"
  (let* ([sent (length (servers:record-of c-record))]
         [waiting (spawn-task (lambda (restore) (jsonrpc:request c "wait" '())))])
    (servers:wait-for-records c-record (+ sent 1))
    (check-equal? '() cancels)
    (cancel-waiting! waiting)
    (check-equal? 1 (length cancels))
    (set! cancels '())))

(test "jsonrpc:request-async calls one of its procedures in a task; cancelled first, it calls neither"
  (let* ([answers '()] [note! (lambda (x) (set! answers (cons x answers)))])
    (check (jsonrpc:pending? (jsonrpc:request-async c "echo" '#(7) note! note!)))
    (let ([p (jsonrpc:request-async c "wait" '() note! note!)])
      (jsonrpc:cancel! p)
      (jsonrpc:cancel! p)
      (check-equal? '#(8) (jsonrpc:request c "echo" '#(8)))
      (check-equal? '(#(7)) answers)
      (check-equal? 1 (length cancels)))))

(test "a connection without a cancel clause sends nothing when a waiting task is cancelled, and two connections each read their own frames"
  (let-values ([(quiet record) (servers:start! "quiet" (jsonrpc:handlers))])
    (let ([waiting (spawn-task (lambda (restore) (jsonrpc:request quiet "wait" '())))])
      (servers:wait-for-records record 1)
      (cancel-waiting! waiting)
      (check-equal? '#(1) (jsonrpc:request quiet "echo" '#(1)))
      (check-equal? '("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"wait\"," "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"echo\",")
        (map (lambda (line) (substring line 0 (min 40 (string-length line)))) (servers:record-of record))))
    (let ([both (list (spawn-task (lambda (restore) (jsonrpc:request c "echo" '#("c"))))
                      (spawn-task (lambda (restore) (jsonrpc:request quiet "echo" '#("quiet")))))])
      (check-equal? '(#("c") #("quiet")) (map test-runner:join both)))
    (jsonrpc:stop! quiet)))

(test "bad arguments raise"
  (check-equal? "not a string" (message (lambda () (jsonrpc:request c 'echo '()))))
  (check-equal? "not a JSON object, array or null" (message (lambda () (jsonrpc:request c "echo" "params"))))
  (check-equal? "not a list of a program and its arguments" (message (lambda () (jsonrpc:start "x" '() (jsonrpc:handlers)))))
  (check-equal? "a connection keeps standard error apart itself"
    (message (lambda () (jsonrpc:start "x" '("true") (jsonrpc:handlers) (processes:options [separate-stderr #t]))))))
