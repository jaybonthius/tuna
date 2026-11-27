(import (tuna) (test) (test-runner) (test-user) (buffers) (document) (views) (layout) (files) (command-line-test))

(test-runner:wait-until (lambda () (command-line-test:showing? "g.txt")))

(test "the restart brings the view back on the other file, at its end"
  (check-equal? '("g.txt" 301) (command-line-test:shown)))

(command-line-arguments (list "g.txt" "h.txt"))
(load-module! '(command-line))
(test-runner:wait-until (lambda () (command-line-test:showing? "h.txt")))
(test-user:settle)

(test "the last file shows from its first line, its point there too"
  (let* ([v (layout:selected-view)] [doc (buffers:document (views:buffer v))])
    (check-equal? '(1 1) (list (document:line doc (views:point v)) (document:line doc (views:top v #f))))))
