(import (tuna) (test) (views) (buffers) (views-test session))

(define gone (buffers:make "*gone*<7>" "gone\n"))
(define notes (views-test/session:make-notes!))
(define v (views-test/session:atom-view (views-test/session:make-host!)))

(test "a buffer of the gone entry's name made later is not in the view's history"
  (check-equal? '() (views:previous-buffers v)))
