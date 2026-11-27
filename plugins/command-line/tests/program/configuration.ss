(import (tuna) (test) (test-runner) (options) (web) (command-line) (command-line-test))

(options:set! web:port (call-with-input-file (command-line-test:home-path "configured-port") read))

(test-runner:wait-until (lambda () (and (web:url) (command-line-test:showing? "a.txt"))))

(test "the file named is shown at its +N, and web listens on the port the command line set"
  (check-equal? '("a.txt" 2) (command-line-test:shown))
  (check-equal? (format "http://127.0.0.1:~a/" (web:port)) (web:url)))

(exit)
