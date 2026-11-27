(import (tuna) (test) (views) (buffers) (files) (views-test session))

(define notes (views-test/session:make-notes!))
(define v (views-test/session:atom-view (views-test/session:make-host!)))

(call-with-output-file (views-test/session:home-file "a.txt") (lambda (p) (put-string p "one\ntwo\nthree\n")) 'replace)
(views:set-point! v 12)
(views:set-buffer! v (buffers:make "late" "late\n"))
(views:set-point! v 3)

(define x (views:make (files:visit "~/a.txt")))
(views:set-point! x 9)
(views:drop! x)

(test "the view's history holds the buffer it left"
  (check-equal? (list notes) (views:previous-buffers v)))

(views-test/session:end-batch!)
