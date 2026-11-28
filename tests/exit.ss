(import (tuna) (test) (test-runner) (program) (processes))

(define (read-lines file)
  (if (file-exists? file)
      (call-with-input-file file
        (lambda (p) (let loop () (let ([line (get-line p)]) (if (eof-object? line) '() (cons line (loop)))))))
      '()))

;; Each configuration in exit/ exits its own Tuna. It notes its unloads and
;; reports in the home's events file, so what the exit did is that file
;; and the program's status, and anything else Tuna reports fails the test
;; through standard error.
(define (exit-run name)
  (let ([home (string-append (getenv "HOME") "/" name)])
    (test-runner:make-home! home (string-append "exit/" name ".ss"))
    (let-values ([(status output errors) (program:run home '())])
      (check-equal? "" errors)
      (values status (read-lines (string-append home "/events"))))))

(define unloads '("configuration unloading" "user unloading" "keeper unloading"))

(test "exit takes back every change and unloads every module, the newest first"
  (let-values ([(status events) (exit-run "end")])
    (check-equal? 0 status)
    (check-equal? unloads events)))

(test "exit in a task leaves the task before any module unloads, so its winders can still use a module"
  (let-values ([(status events) (exit-run "winder")])
    (check-equal? 0 status)
    (check-equal? (cons "leaving the task" unloads) events)))

(test "an after-thunk that pauses while exit leaves its task runs to its end before any module unloads"
  (let-values ([(status events) (exit-run "winder-pause")])
    (check-equal? 0 status)
    (check-equal? (cons "leaving the task" unloads) events)))

(test "an after-thunk's raise while exit leaves its task is reported, and Tuna still exits"
  (let-values ([(status events) (exit-run "raise")])
    (check-equal? 0 status)
    (check-equal? (cons "reported car" unloads) events)))

(test "that raise is taken where it happens, so the task's handler never sees it and the other after-thunks run"
  (let-values ([(status events) (exit-run "guard")])
    (check-equal? 0 status)
    (check-equal? (append '("reported car" "leaving the task") unloads) events)))

(test "in a command, that raise is reported once and Tuna exits"
  (let-values ([(status events) (exit-run "command")])
    (check-equal? 0 status)
    (check-equal? (cons "reported car" unloads) events)))

(test "an exit called while another leaves its task keeps the first exit's status"
  (let-values ([(status events) (exit-run "status")])
    (check-equal? 0 status)
    (check-equal? unloads events)))

(test "at exit a paused task is left before any module unloads, and its handlers do not run"
  (let-values ([(status events) (exit-run "paused")])
    (check-equal? 0 status)
    (check-equal? (cons "leaving the task" unloads) events)))

(test "a paused task whose after-thunk exits only ends, and the exit under way keeps its status"
  (let-values ([(status events) (exit-run "paused-exit")])
    (check-equal? 0 status)
    (check-equal? (cons "leaving the task" unloads) events)))

(test "a quit asked for while exit leaves its task does not cut an unload action short"
  (let-values ([(status events) (exit-run "quit")])
    (check-equal? 0 status)
    (check-equal? (cons "busy unload ended" unloads) events)))

(test "on another thread's task, exit asks the main thread to exit, and unload actions run in tasks"
  (let-values ([(status events) (exit-run "thread")])
    (check-equal? 0 status)
    (check-equal? '("configuration unloading" "unloading in a task" "user unloading" "keeper unloading") events)))

(test "on a thread Chez forked, exit asks the main thread to exit and returns"
  (let-values ([(status events) (exit-run "chez-thread")])
    (check-equal? 0 status)
    (check-equal? (cons "exit returned" unloads) events)))

(test "a raise from an after-thunk of Chez's own dynamic-wind can be handled, and Tuna exits once the task ends"
  (let-values ([(status events) (exit-run "chez-winder")])
    (check-equal? 0 status)
    (check-equal? (append '("handler ran" "the task goes on" "after a pause") unloads) events)))

(test "a cancel that cuts an after-thunk while exit leaves its task is not reported, and exit still asks about it"
  (let-values ([(status events) (exit-run "cancel-winder")])
    (check-equal? 0 status)
    (check-equal? (cons "asked about a cancel" unloads) events)))

(test "exit ends the batch it is called in before anything stops or unloads, so batch-ended sees the batch's changes"
  (let-values ([(status events) (exit-run "batch")])
    (check-equal? 0 status)
    (check-equal? (cons "batch ended: changed in the exiting batch" unloads) events)))

(test "exit goes on when a cancel ends its batch-ended task"
  (let-values ([(status events) (exit-run "batch-cancelled")])
    (check-equal? 0 status)
    (check-equal? (cons "batch-ended cancels itself" unloads) events)))

;; The configuration notes the first event once exit is held up; one
;; SIGINT must then free it.
(define (interrupted-run name held)
  (let ([home (string-append (getenv "HOME") "/" name)])
    (test-runner:make-home! home (string-append "exit/" name ".ss"))
    (let ([r (program:start (program:tuna) home '() '())])
      (test-runner:wait-until (lambda () (member held (read-lines (string-append home "/events")))))
      (program:signal! r (processes:signal int))
      (let-values ([(status output errors) (program:wait r)])
        (check-equal? "" errors)
        (values status (read-lines (string-append home "/events")))))))

(test "a Ctrl-C stops a batch-ended that holds the exit up in a pause, and Tuna exits"
  (let-values ([(status events) (interrupted-run "batch-stuck" "batch-ended waits")])
    (check-equal? 0 status)
    (check-equal? (cons "batch-ended waits" unloads) events)))

(test "a Ctrl-C stops a batch-ended that holds the exit up on the main thread, and Tuna exits"
  (let-values ([(status events) (interrupted-run "batch-spin" "batch-ended spins")])
    (check-equal? 0 status)
    (check-equal? (cons "batch-ended spins" unloads) events)))

(test "a Ctrl-C stops again a stopped task whose after-thunk holds the exit up, and Tuna exits"
  (let-values ([(status events) (interrupted-run "winder-stuck" "after-thunk waits")])
    (check-equal? 0 status)
    (check-equal? (cons "after-thunk waits" unloads) events)))

(test "a Ctrl-C stops again a thread's task that the unload stopped and whose after-thunk holds the exit up, and Tuna exits"
  (let-values ([(status events) (interrupted-run "thread-winder-stuck" "thread's after-thunk waits")])
    (check-equal? 0 status)
    (check-equal? '("configuration unloading" "thread's after-thunk waits" "user unloading" "keeper unloading") events)))
