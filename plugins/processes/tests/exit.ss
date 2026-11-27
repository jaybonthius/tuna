(import (tuna) (test) (test-runner) (processes) (recorder))

(define (alive? pid) (file-exists? (format "/proc/~a" pid)))

(test "at exit a user process on a terminal is hung up, one on pipes that neither reads nor writes runs on, and an own process stops"
  (let ([home (string-append (getenv "HOME") "/exiting")] [r (recorder:make)])
    (test-runner:make-home! home "exit/init.ss")
    (processes:start (car (command-line)) '() (recorder:on-output r) (recorder:on-exit r)
      (processes:options [directory home] [environment (test-runner:home-environment home)]))
    (check-equal? '((eof 0) (exit 0)) (recorder:wait-for-exit r))
    (let ([pids (call-with-input-file (string-append home "/pids") read)])
      (check (for-all integer? pids))
      (test-runner:wait-until (lambda () (not (alive? (car pids)))))
      (check (alive? (cadr pids)))
      (test-runner:wait-until (lambda () (not (alive? (caddr pids)))))
      (processes:run "kill" (list (number->string (cadr pids)))))))
