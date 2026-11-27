(import (tuna) (test) (test-runner) (test-user) (buffers) (files) (command-line) (files-test session))

(test-runner:wait-until (lambda () (files-test/session:showing? "b.txt")))

(test "the command line's files are visited, and the last is shown at +N; a flag, which starts with --, is not a file"
  (check-equal? '("a.txt" "b.txt") (files-test/session:file-names))
  (check-equal? '("b.txt" 3) (files-test/session:shown)))

(buffers:replace! (files:buffer-visiting (files-test/session:home-path "b.txt")) 1 1 "unsaved ")
(test-user:settle)
(exit)
