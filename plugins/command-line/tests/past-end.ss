(import (tuna) (test) (test-runner) (command-line-test))

(command-line-test:write-file! "f.txt" "one\ntwo\nthree\nfour\n")

(command-line-arguments (list "+99" "f.txt"))
(load-module! '(command-line))
(test-runner:wait-until (lambda () (command-line-test:showing? "f.txt")))

(test "+N past the last line goes to the end of the file, after its final newline"
  (check-equal? '("f.txt" 5) (command-line-test:shown)))
