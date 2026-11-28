(import (tuna) (test) (test-runner) (processes))

(define (read-lines file)
  (if (file-exists? file)
      (call-with-input-file file
        (lambda (p) (let loop () (let ([line (get-line p)]) (if (eof-object? line) '() (cons line (loop)))))))
      '()))

;; Each configuration in asking/ exits its own Tuna, noting its reports,
;; the questions it was asked and its unload in the home's events file, so
;; what the exit did is that file and the program's status.
(define (exit-run name)
  (let ([home (string-append (getenv "HOME") "/" name)])
    (test-runner:make-home! home (string-append "asking/" name ".ss"))
    (let-values ([(status output errors)
                  (processes:run (car (command-line)) '() ""
                    (processes:options [directory home] [environment (test-runner:home-environment home)] [separate-stderr #t]))])
      (check-equal? "" (utf8->string errors))
      (values status (read-lines (string-append home "/events"))))))

(define question "asked: Exception in car: () is not a pair; exit anyway? (y or n) ")

(test "an after-thunk that raises while exit leaves its task is reported, then the plugin asks whether to exit anyway, and y exits"
  (let-values ([(status events) (exit-run "yes")])
    (check-equal? 0 status)
    (check-equal? (list "reported car" question "configuration unloading") events)))

(test "so does one in the command a key runs"
  (let-values ([(status events) (exit-run "key")])
    (check-equal? 0 status)
    (check-equal? (list "reported car" question "configuration unloading") events)))

(test "n, or C-g, keeps Tuna running and drops the exit that asked; a later exit exits as usual"
  (let-values ([(status events) (exit-run "no")])
    (check-equal? 0 status)
    (check-equal? (list "reported car" question "reported car" question "still running"
                        "configuration unloading")
                  events)))

(test "when several after-thunks raise, each is reported as the task leaves, then each is asked about in turn, until an answer is n"
  (let-values ([(status events) (exit-run "several")])
    (check-equal? 0 status)
    (check-equal? (list "reported vector-ref" "reported car"
                        "asked: Exception in vector-ref: 0 is not a valid index for #(); exit anyway? (y or n) "
                        question "still running" "configuration unloading")
                  events)))

(test "with no answer within 5 seconds, Tuna exits"
  (let-values ([(status events) (exit-run "timeout")])
    (check-equal? 0 status)
    (check-equal? '("reported car" "configuration unloading") events)))

(test "a question that cannot be asked is reported, and Tuna exits"
  (let-values ([(status events) (exit-run "no-reader")])
    (check-equal? 0 status)
    (check-equal? '("reported car" "reported reader" "configuration unloading") events)))

(test "while exit waits for its task's paused after-thunk, a raise in another task is reported but not asked about"
  (let-values ([(status events) (exit-run "other-task")])
    (check-equal? 0 status)
    (check-equal? '("reported vector-ref" "configuration unloading") events)))

(test "a paused task's after-thunk that raises as exit leaves it is reported, its handler does not run, and the exit goes on without asking"
  (let-values ([(status events) (exit-run "paused")])
    (check-equal? 0 status)
    (check-equal? '("reported car" "configuration unloading") events)))

(test "without the plugin, the raise is reported and Tuna exits"
  (let-values ([(status events) (exit-run "without")])
    (check-equal? 0 status)
    (check-equal? '("reported car" "configuration unloading") events)))
