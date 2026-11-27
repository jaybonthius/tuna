(import (test) (test-runner))

(define home (string-append (getenv "HOME") "/restarted"))

(define (passes file)
  (let-values ([(status errors) (test-runner:run-file file home)])
    (check-equal? 0 status)
    (check-equal? "" errors)))

(test "tabs, the tab each shows and the selected view outlast a restart"
  (passes "restart/first.ss")
  (let ([expected (call-with-input-file (string-append home "/expected.ss") read)])
    (check-equal? 'layout-tabs:container (car (cadddr (caddr (car expected)))))
    (check-equal? 2 (length (caddr expected)))
    (check-equal? (cadr expected) (car (caddr expected))))
  (passes "restart/second.ss"))
