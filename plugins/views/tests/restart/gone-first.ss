(import (tuna) (test) (views) (buffers) (views-test session))

(define notes (views-test/session:make-notes!))
(define v (views-test/session:atom-view (views-test/session:make-host!)))
(define gone (buffers:make "*gone*<7>" "gone\n"))

(views:set-buffer! v gone)
(views:set-point! v 3)
(views:set-buffer! v notes)

(test "the view's history holds a buffer no start makes"
  (check-equal? (list gone) (views:previous-buffers v)))

(views-test/session:end-batch!)
