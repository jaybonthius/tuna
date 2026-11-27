(import (tuna) (test) (test-user) (buffers) (files) (layout) (views) (document) (session))

(call-with-output-file (session:home-path "a.txt") (lambda (p) (put-string p "one\ntwo\nthree\n")))
(call-with-output-file (session:home-path "b.txt") (lambda (p) (put-string p "alpha\nbeta\ngamma\ndelta\n")))
(files:visit (session:home-path "a.txt"))
(layout:switch-to-buffer (files:visit (session:home-path "b.txt")))
(views:set-point! (layout:selected-view) (document:line-start (buffers:document (session:b)) 3))
(test-user:settle)

(test "an edit before point moves the cursor with its text"
  (buffers:replace! (session:b) 1 1 "unsaved ")
  (check-equal? '("b.txt" 3 "gamma") (session:shown)))

(test-user:settle)
(exit)
