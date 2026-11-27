(import (test) (test-runner))

(define (passes file home)
  (let-values ([(status errors) (test-runner:run-file file home)])
    (check-equal? 0 status)
    (check-equal? "" errors)))

(test "a strip and a float desktop come back after a restart with the selected view; popups and their selections do not"
  (let ([home (string-append (getenv "HOME") "/restarted")])
    (passes "restart/first.ss" home)
    (passes "restart/second.ss" home)))
