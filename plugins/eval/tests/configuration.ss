(import (test) (test-runner))

(test "the configuration's file evaluates as the configuration, and C-c C-k in it runs it again"
  (let ([home (string-append (getenv "HOME") "/configured")])
    (test-runner:make-home! home "configuration/init.ss")
    (let-values ([(status errors) (test-runner:run-file "configuration/evaluating.ss" home)])
      (check-equal? 0 status)
      (check-equal? "" errors))))
