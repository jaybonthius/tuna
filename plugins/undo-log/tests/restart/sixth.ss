(import (tuna) (test) (test-user) (buffers) (files) (layout) (views) (editing) (undo-log-test session))

(call-with-output-file (undo-log-test/session:home-path "a.txt") (lambda (p) (put-string p "one\n")))
(call-with-output-file (undo-log-test/session:home-path "b.txt") (lambda (p) (put-string p "alpha\nbeta\ngamma\n")))
(files:visit (undo-log-test/session:home-path "a.txt"))
(layout:switch-to-buffer (files:visit (undo-log-test/session:home-path "b.txt")))
(views:set-point! (layout:selected-view) 1)
(views:add-cursor! (layout:selected-view) 7)
(views:add-cursor! (layout:selected-view) 12)

(test "typing at three cursors leaves each after what it typed"
  (test-user:type! "x")
  (check-equal? '(2 9 15) (undo-log-test/session:points)))

(test-user:settle)
(exit)
