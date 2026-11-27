(import (test) (test-runner))

(test "the configuration's modes, lighters and hook entries"
  (let ([home (string-append (getenv "HOME") "/configured")])
    (test-runner:make-home! home "configuration/init.ss")
    (let-values ([(status errors) (test-runner:run-file "configuration/configured.ss" home)])
      (check-equal? 0 status)
      (check-equal? "" errors))))
