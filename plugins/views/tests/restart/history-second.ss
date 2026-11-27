(import (tuna) (test) (views) (buffers) (files) (views-test session))

(define notes (views-test/session:make-notes!))
(define v (views-test/session:atom-view (views-test/session:make-host!)))

(test "a view whose buffer is not made yet shows nothing, and its history holds the buffers that are"
  (check-equal? #f (views:buffer v))
  (check-equal? (list notes) (views:previous-buffers v)))

(test "the buffer a view showed comes back to it where it was once a buffer of its name is made"
  (let ([late (buffers:make "late" "late\n")])
    (check-equal? (list late 3) (list (views:buffer v) (views:point v)))
    (views:set-buffer! v notes)
    (check-equal? (list 12 (list late)) (list (views:point v) (views:previous-buffers v)))))

(test "a file reopened from the saved visits opens where it was left"
  (let ([file (files:visit "~/a.txt")])
    (check-equal? 9 (views:last-point file))
    (let ([y (views:make notes)])
      (views:set-buffer! y file)
      (check-equal? 9 (views:point y)))))
