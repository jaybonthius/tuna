(import (test) (test-runner))

(define home (string-append (getenv "HOME") "/restarted"))

(define (passes file)
  (let-values ([(status errors) (test-runner:run-file file home)])
    (check-equal? 0 status)
    (check-equal? "" errors)))

(test "the order of use outlasts a restart, and the saved names no buffer takes by the first idle go"
  (for-each passes '("restart/first.ss" "restart/second.ss" "restart/third.ss" "restart/fourth.ss")))
