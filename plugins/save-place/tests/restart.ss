(import (test) (test-runner))

(test "a killed file's place, and the point views kept for a file open at exit, outlast a restart"
  (let ([home (string-append (getenv "HOME") "/restarted")])
    (for-each
      (lambda (file)
        (let-values ([(status errors) (test-runner:run-file file home)])
          (check-equal? 0 status)
          (check-equal? "" errors)))
      '("restart/first.ss" "restart/second.ss"))))
