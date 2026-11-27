(import (tuna) (test) (test-user) (buffers) (files) (layout) (views) (document) (undo-log-test session))

(call-with-output-file (undo-log-test/session:home-path "a.txt") (lambda (p) (put-string p "one\ntwo\nthree\n")))
(call-with-output-file (undo-log-test/session:home-path "b.txt") (lambda (p) (put-string p "alpha\nbeta\ngamma\ndelta\n")))
(files:visit (undo-log-test/session:home-path "a.txt"))
(layout:switch-to-buffer (files:visit (undo-log-test/session:home-path "b.txt")))
(views:set-point! (layout:selected-view) (document:line-start (buffers:document (undo-log-test/session:b)) 3))
(test-user:settle)

(test "an edit before point moves the cursor with its text"
  (buffers:replace! (undo-log-test/session:b) 1 1 "unsaved ")
  (check-equal? '("b.txt" 3 "gamma") (undo-log-test/session:shown)))

(test-user:settle)
(exit)
