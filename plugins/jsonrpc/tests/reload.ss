(import (tuna) (test) (test-runner) (web) (processes) (jsonrpc) (jsonrpc-test servers))

(test "unloading jsonrpc stops the programs of its connections, whichever module started them, and their waiting requests get jsonrpc:&ended"
  (let*-values ([(owner) (make-owner '(starter))]
                [(c record) (call-as-owner owner (lambda () (jsonrpc-test/servers:start! "fake" (jsonrpc:handlers))))])
    (check-equal? '#(1) (jsonrpc:request c "echo" '#(1)))
    (let ([process (jsonrpc:connection-process c)]
          [waiting (spawn-task (lambda (restore) (jsonrpc-test/servers:raised (lambda () (jsonrpc:request c "wait" '())))))])
      (jsonrpc-test/servers:wait-for-records record 2)
      (check-equal? #f (processes:status process))
      (unload-owner! (module-owner '(jsonrpc)))
      (test-runner:wait-until (lambda () (processes:status process)))
      (check (integer? (processes:status process)))
      (check-equal? '(ended #f) (test-runner:join waiting)))
    (unload-owner! owner)))

;; A form's names are found when the form is evaluated, so the modules
;; load again before the form that uses them.
(load-module! '(jsonrpc))
(load-module! '(jsonrpc-test servers))

(test "jsonrpc loaded again starts connections"
  (let ([again (jsonrpc-test/servers:start "again" (jsonrpc:handlers))])
    (check-equal? '#(2) (jsonrpc:request again "echo" '#(2)))
    (jsonrpc:stop! again)))

(test "unloading the module that started a connection stops its program"
  (let* ([owner (make-owner '(starter))]
         [c (call-as-owner owner (lambda () (jsonrpc-test/servers:start "fake" (jsonrpc:handlers))))]
         [process (jsonrpc:connection-process c)])
    (check-equal? '#(3) (jsonrpc:request c "echo" '#(3)))
    (unload-owner! owner)
    (test-runner:wait-until (lambda () (processes:status process)))))

(test "once the module that started a connection unloads, it is not running, and the requests other modules wait for get jsonrpc:&ended"
  (let*-values ([(owner) (make-owner '(starter))]
                [(c record) (call-as-owner owner (lambda () (jsonrpc-test/servers:start! "fake" (jsonrpc:handlers))))])
    (let ([failed #f])
      (jsonrpc:request-async c "wait" '() (lambda (v) (void)) (lambda (e) (set! failed e)))
      (let ([waiting (spawn-task (lambda (restore) (jsonrpc-test/servers:raised (lambda () (jsonrpc:request c "wait" '())))))])
        (jsonrpc-test/servers:wait-for-records record 2)
        (unload-owner! owner)
        (check (not (jsonrpc:running? c)))
        (check-equal? '(ended #f) (test-runner:join waiting)))
      (test-runner:wait-until (lambda () failed))
      (check (jsonrpc:ended? failed))
      (check-equal? '(ended #f) (jsonrpc-test/servers:raised (lambda () (jsonrpc:request c "echo" '())))))))
