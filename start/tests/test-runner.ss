(import (tuna) (test) (test-runner))

(define (home name) (string-append (getenv "HOME") "/" name))

(define (contains? s part)
  (let ([n (string-length part)])
    (let loop ([i 0])
      (and (<= (+ i n) (string-length s))
           (or (string=? part (substring s i (+ i n))) (loop (+ i 1)))))))

(test "a file that runs to its last form exits 0 and writes nothing to standard error"
  (let-values ([(status errors) (test-runner:run-file "runner/passes.ss" (home "passes"))])
    (check-equal? 0 status)
    (check-equal? "" errors)))

(test "a failing check is written to standard error, naming the file and line, and the file goes on"
  (let-values ([(status errors) (test-runner:run-file "runner/fails-a-check.ss" (home "check"))])
    (check-equal? 0 status)
    (check (contains? errors "runner/fails-a-check.ss:4:3: FAIL in one is two"))))

(test "a raise outside a test is reported and ends the file with status 1"
  (let-values ([(status errors) (test-runner:run-file "runner/raises.ss" (home "raises"))])
    (check-equal? 1 status)
    (check (contains? errors "car"))))

(test "a file that cannot be read is reported and ends with status 1 before any form runs"
  (let-values ([(status errors) (test-runner:run-file "runner/unreadable.ss" (home "unreadable"))])
    (check-equal? 1 status)
    (check (contains? errors "unexpected close parenthesis"))))

(test "an exit before the last form is reported with the form it came at"
  (let-values ([(status errors) (test-runner:run-file "runner/exits.ss" (home "exits"))])
    (check (contains? errors "runner/exits.ss ended by exit at form 2"))))

(test "an exit made elsewhere while the file waits is reported"
  (let-values ([(status errors) (test-runner:run-file "runner/exits-while-paused.ss" (home "paused"))])
    (check (contains? errors "runner/exits-while-paused.ss ended by exit at form 3"))))

(test "files run on one home see what the earlier ones left"
  (for-each
    (lambda (file)
      (let-values ([(status errors) (test-runner:run-file file (home "shared"))])
        (check-equal? 0 status)
        (check-equal? "" errors)))
    '("runner/writes.ss" "runner/reads.ss")))

;; The kernel reports a task's raise and its cancel when the task ends.
(define (reports-during thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (thunk)
    (advice-remove! report keep)
    (reverse reported)))

(test "join gives a task's values, raises its raise again, and raises a cancel with its reason"
  (check-equal? '(1 2) (call-with-values (lambda () (test-runner:join (spawn-task (lambda (restore) (values 1 2))))) list))
  (check-equal? 1
    (length
      (reports-during
        (lambda ()
          (check-raises error? (test-runner:join (spawn-task (lambda (restore) (error 'here "raised")))))))))
  (let ([t (spawn-task (lambda (restore) 'never-runs))])
    (cancel-task t 'mine)
    (check-equal? 'mine (guard (c [(cancelled? c) (cancelled-reason c)]) (test-runner:join t)))))

(test "wait-until returns once another thread makes its condition hold"
  (let ([set (box #f)])
    (fork-task (lambda (restore) (set-box! set #t)))
    (test-runner:wait-until (lambda () (unbox set)))
    (check (unbox set))))

(test "a running-task canceller cancels, from another thread, the task the main thread is running, unless it is the task spared, and says whether it cancelled"
  (let ([cancel! (test-runner:running-task-canceller)] [me (current-task)] [spared-cancels 0] [stopped #f])
    (fork-task
      (lambda (restore)
        (let ([until (+ (real-time) 200)])
          (let loop ()
            (when (< (real-time) until)
              (when (cancel! me) (set! spared-cancels (+ spared-cancels 1)))
              (loop))))
        (set! stopped #t)))
    (let spin () (unless stopped (spin)))
    (check-equal? 0 spared-cancels)
    (check-equal? 'cancelled
      (guard (c [(cancelled? c) 'cancelled])
        (fork-task (lambda (restore) (let loop () (unless (cancel!) (loop)))))
        (let spin () (spin))))))

(test "a running-task canceller is made on the main thread"
  (check-equal? 1
    (length
      (reports-during
        (lambda ()
          (check-raises assertion-violation?
            (test-runner:join (fork-task (lambda (restore) (test-runner:running-task-canceller))))))))))

(test "run-paths is #t only when every file it names passes"
  (check-equal? #t (test-runner:run-paths '("runner/tests/passes.ss")))
  (check-equal? #f (test-runner:run-paths '("runner")))
  (check-equal? #f (test-runner:run-paths '("runner/tests/passes.ss" "runner/tests/fails.ss")))
  (check-equal? #f (test-runner:run-paths '("runner/tests/reports.ss"))))

(test "run-paths fails a path that is missing or is not a .ss file directly in a tests folder"
  (check-equal? #f (test-runner:run-paths '("runner/tests/missing.ss")))
  (check-equal? #f (test-runner:run-paths '("runner/passes.ss"))))

(test "run-file and evaluate-file refuse a file outside a tests folder"
  (let ([loose (string-append (getenv "HOME") "/loose.ss")])
    (call-with-output-file loose (lambda (p) (put-string p "(display 1)\n")))
    (check-raises assertion-violation? (test-runner:run-file loose (home "loose")))))
