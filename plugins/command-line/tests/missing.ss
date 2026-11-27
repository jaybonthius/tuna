(import (tuna) (test) (test-runner) (buffers) (document) (files) (command-line-test) (web-test tasks))

(command-line-arguments (list "+2" "c.txt"))

;; With no echo area loaded, files' message for a new file is a warning,
;; which the visit outlives.
(define reported
  (web-test/tasks:reports-during
    (lambda ()
      (load-module! '(command-line))
      (test-runner:wait-until (lambda () (command-line-test:showing? "c.txt"))))))

(test "a file that does not exist is visited as an empty buffer of one line, so +2 goes to line 1"
  (check-equal? '("c.txt" 1) (command-line-test:shown))
  (check-equal? "" (document:text (buffers:document (files:buffer-visiting (command-line-test:home-path "c.txt")))))
  (check (not (file-exists? (command-line-test:home-path "c.txt")))))

(test "a warning raised while a file is visited is reported, and the visit goes on"
  (check-equal? '("(New file)") (map condition-message reported))
  (check (warning? (car reported))))
