(import (tuna) (test) (test-runner) (document) (buffers) (files) (command-line) (session))

(test-runner:wait-until (lambda () (and (= 2 (length (files:buffers))) (session:showing? "b.txt"))))

(test "a restart visits the files that were open, and the layout's view comes back; without undo the unsaved edit is gone, the view keeping the point it had after it"
  (check-equal? '("a.txt" "b.txt") (session:file-names))
  (check-equal? '("b.txt" 4) (session:shown))
  (check-equal? "alpha\nbeta\ngamma\ndelta\n" (document:text (buffers:document (files:buffer-visiting (session:home-path "b.txt"))))))

(exit)
