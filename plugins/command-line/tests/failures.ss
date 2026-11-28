(import (tuna) (test) (test-runner) (files) (command-line-test))

(command-line-test:write-file! "e.txt" "1\n2\n3\n")
(command-line-test:write-file! "f.txt" "one\ntwo\nthree\nfour\n")
(mkdir (command-line-test:home-path "folder"))

(command-line-arguments (list "+2" "e.txt" "+3" "f.txt" "~/folder" "+9"))

(define reported
  (test-runner:reports-during
    (lambda ()
      (load-module! '(command-line))
      (test-runner:wait-until (lambda () (command-line-test:showing? "f.txt")))
      (test-runner:wait-for-batch))))

(test "a file that cannot be visited is reported and skipped, and the files before it stay visited"
  (check-equal? 1 (length reported))
  (check-equal? '(files:read-document "~a is a folder" ("~/folder"))
                (list (condition-who (car reported)) (condition-message (car reported)) (condition-irritants (car reported))))
  (check (files:buffer-visiting (command-line-test:home-path "e.txt"))))

(test "a +N after the last file moves nothing, and the last file visited is shown at its own +N"
  (check-equal? '("f.txt" 3) (command-line-test:shown)))
