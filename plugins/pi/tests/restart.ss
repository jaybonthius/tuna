(import (test) (test-runner))

(define (passes file home)
  (let-values ([(status errors) (test-runner:run-file file home)])
    (check-equal? 0 status)
    (check-equal? "" errors)))

(test "a quit ends Pi, and the next start starts Pi again on the chat's session, with pi:command as the configuration sets it"
  (let ([home (string-append (getenv "HOME") "/restarted")])
    (passes "restart/first.ss" home)
    (passes "restart/second.ss" home)))
