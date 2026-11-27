(import (test) (test-runner))

(test "M-:'s history is saved data, so it outlives Tuna"
  (let ([home (string-append (getenv "HOME") "/restarted")])
    (for-each
      (lambda (file)
        (let-values ([(status errors) (test-runner:run-file file home)])
          (check-equal? 0 status)
          (check-equal? "" errors)))
      '("restart/first.ss" "restart/second.ss"))))
