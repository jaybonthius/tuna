(import (tuna) (test) (views) (buffers) (views-test session))

(views-test/session:make-notes!)
(views-test/session:make-host!)

(test "after drawing atoms at two starts, one view came back"
  (check-equal? '(300) (filter views:find (map (lambda (i) (+ i 1)) (iota 400)))))
