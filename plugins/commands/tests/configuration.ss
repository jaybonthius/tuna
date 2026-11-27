(import (test) (test-runner))

(test "commands the configuration defines, and its hook entries, as a module's code sees them"
  (let ([home (string-append (getenv "HOME") "/configured")])
    (test-runner:make-home! home "configuration/init.ss")
    (let-values ([(status errors) (test-runner:run-file "configuration/defined.ss" home)])
      (check-equal? 0 status)
      (check-equal? "" errors))))
