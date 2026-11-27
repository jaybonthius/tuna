(import (tuna) (test) (test-runner) (files) (command-line) (session))

(test-runner:wait-until (lambda () (= 3 (length (files:buffers)))))

(test "the quit command keeps the open files for the next start"
  (check-equal? '("a.txt" "b.txt" "c.txt") (session:file-names)))

(exit)
