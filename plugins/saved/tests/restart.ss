(import (test) (test-runner))

(define (home name) (string-append (getenv "HOME") "/" name))

(define (passes file home)
  (let-values ([(status errors) (test-runner:run-file file home)])
    (check-equal? 0 status)
    (check-equal? "" errors)))

(test "saved data outlives a restart, written whole before Tuna exits"
  (passes "restart/first.ss" (home "restarted"))
  (passes "restart/second.ss" (home "restarted")))

(test "a write that fails is reported, and Tuna still exits normally"
  (passes "restart/write-fails.ss" (home "failing")))
