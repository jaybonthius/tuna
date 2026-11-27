(import (tuna) (test) (test-runner) (options) (web) (processes) (jsonrpc) (servers))

;; jsonrpc loads web through modes and keys; web listens on 7337 by
;; default, which other tests' Tunas may hold, so this one takes a port of
;; its own before web starts listening, after the batch it loaded in.
(options:set! web:port (+ 20000 (mod (get-process-id) 20000)))

(test "unloading jsonrpc stops the programs of its connections, whichever module started them, and their waiting requests get jsonrpc:&ended"
  (let*-values ([(owner) (make-owner '(starter))]
                [(c record) (call-as-owner owner (lambda () (servers:start! "fake" (jsonrpc:handlers))))])
    (check-equal? '#(1) (jsonrpc:request c "echo" '#(1)))
    (let ([process (jsonrpc:connection-process c)]
          [waiting (spawn-task (lambda (restore) (servers:raised (lambda () (jsonrpc:request c "wait" '())))))])
      (servers:wait-for-records record 2)
      (check-equal? #f (processes:status process))
      (unload-owner! (module-owner '(jsonrpc)))
      (test-runner:wait-until (lambda () (processes:status process)))
      (check (integer? (processes:status process)))
      (check-equal? '(ended #f) (test-runner:join waiting)))
    (unload-owner! owner)))

;; A form's names are found when the form is evaluated, so the modules
;; load again before the form that uses them.
(load-module! '(jsonrpc))
(load-module! '(servers))

(test "jsonrpc loaded again starts connections"
  (let ([again (servers:start "again" (jsonrpc:handlers))])
    (check-equal? '#(2) (jsonrpc:request again "echo" '#(2)))
    (jsonrpc:stop! again)))

(test "unloading the module that started a connection stops its program"
  (let* ([owner (make-owner '(starter))]
         [c (call-as-owner owner (lambda () (servers:start "fake" (jsonrpc:handlers))))]
         [process (jsonrpc:connection-process c)])
    (check-equal? '#(3) (jsonrpc:request c "echo" '#(3)))
    (unload-owner! owner)
    (test-runner:wait-until (lambda () (processes:status process)))))
