(import (test) (test-runner))

(test "the lines given to M-! and compile are offered by M-p after a restart"
  (let ([home (string-append (getenv "HOME") "/restarted")])
    (for-each
      (lambda (file)
        (let-values ([(status errors) (test-runner:run-file file home)])
          (check-equal? 0 status)
          (check-equal? "" errors)))
      '("restart/first.ss" "restart/second.ss"))))
