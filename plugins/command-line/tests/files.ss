(import (tuna) (test) (test-runner) (test-user) (buffers) (files) (command-line-test))

(define visited-before #f)

(command-line-test:write-file! "a.txt" "one\ntwo\nthree\n")
(command-line-test:write-file! "b.txt" "alpha\nbeta\ngamma\ndelta\n")
(command-line-test:write-file! "--odd.txt" "odd\n")

(command-line-arguments
  (list "+3" "a.txt" "--eval=(set! visited-before (map buffers:name (files:buffers)))" "./--odd.txt" "+2" "b.txt"))

(load-module! '(command-line))
(test-runner:wait-until (lambda () (command-line-test:showing? "b.txt")))

(define (names) (list-sort string<? (map buffers:name (files:buffers))))

(test "every other argument is a file, visited in order with the --evals between them"
  (check-equal? '("a.txt") visited-before)
  (check-equal? '("--odd.txt" "a.txt" "b.txt") (names)))

(test "the last file is shown, at the line +N before it names"
  (check-equal? '("b.txt" 2) (command-line-test:shown)))

(test "a reload of files and of the plugin opens no argument again, so a file killed since stays closed"
  (buffers:kill! (files:buffer-visiting (command-line-test:home-path "a.txt")))
  (reload-modules! '((files)))
  (reload-modules! '((command-line)))
  (test-user:settle)
  (check-equal? '("--odd.txt" "b.txt") (names))
  (check-equal? '("b.txt" 2) (command-line-test:shown)))
