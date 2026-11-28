(import (tuna) (test) (test-runner) (processes))

(define (start-with home configuration)
  (test-runner:make-home! home configuration)
  (let-values ([(status output errors)
                (processes:run (car (command-line)) '() ""
                  (processes:options [directory home] [environment (test-runner:home-environment home)] [separate-stderr #t]))])
    (check-equal? 0 status)
    (check-equal? "" (utf8->string errors))))

(test "files:recent-files outlives a restart, and the files gone by the next start leave it then"
  (let ([home (string-append (getenv "HOME") "/recent")])
    (test-runner:make-home! home)
    (for-each (lambda (name) (call-with-output-file (string-append home "/" name) (lambda (p) (put-string p name))))
              '("a.txt" "b.txt" "c.txt"))
    (start-with home "recent-restart/first.ss")
    (delete-file (string-append home "/b.txt"))
    (start-with home "recent-restart/second.ss")))
