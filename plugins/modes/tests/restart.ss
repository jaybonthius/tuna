(import (test) (test-runner))

(test "a mode set by code or by hand lasts only for the process"
  (let ([home (string-append (getenv "HOME") "/restarted")])
    (for-each
      (lambda (file)
        (let-values ([(status errors) (test-runner:run-file file home)])
          (check-equal? 0 status)
          (check-equal? "" errors)))
      '("restart/first.ss" "restart/second.ss"))))
