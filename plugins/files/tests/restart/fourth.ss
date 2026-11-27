(import (tuna) (test) (test-runner) (files) (command-line) (files-test session))

(test-runner:wait-until (lambda () (= 3 (length (files:buffers)))))

(test "the quit command keeps the open files for the next start"
  (check-equal? '("a.txt" "b.txt" "c.txt") (files-test/session:file-names)))

(exit)
