(import (test) (test-runner))

(test "the unsent prompt comes back after a restart, from saved data, in the chat started again on its session"
  (let ([home (string-append (getenv "HOME") "/restarted")])
    (for-each
      (lambda (file)
        (let-values ([(status errors) (test-runner:run-file file home)])
          (check-equal? 0 status)
          (check-equal? "" errors)))
      '("restart/first.ss" "restart/second.ss"))))
