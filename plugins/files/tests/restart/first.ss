(import (tuna) (test) (test-runner) (test-user) (buffers) (files) (command-line) (session))

(test-runner:wait-until (lambda () (session:showing? "b.txt")))

(test "the command line's files are visited, and the last is shown at +N; a flag, which starts with --, is not a file"
  (check-equal? '("a.txt" "b.txt") (session:file-names))
  (check-equal? '("b.txt" 3) (session:shown)))

(buffers:replace! (files:buffer-visiting (session:home-path "b.txt")) 1 1 "unsaved ")
(test-user:settle)
(exit)
