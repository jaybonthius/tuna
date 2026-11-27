(import (tuna) (test) (views) (buffers) (views-test session))

(define notes (views-test/session:make-notes!))
(views-test/session:make-host!)
(define loose (call-with-input-file (views-test/session:home-file "loose") read))

(test "the saved view comes back with its cursors, place, folds, narrowing and options"
  (let ([v (views:find 300)])
    (check-equal? '(12 9 (12 2) 9) (list (views:point v) (views:mark v) (map views:cursor-point (views:cursors v)) (views:top v #f)))
    (check-equal? '(#t (1 25)) (list (views:folded? v 20) (call-with-values (lambda () (views:bounds v)) list)))
    (check-equal? #f (views:with-view v (views:wrap-lines)))))

(test "a view made with views:make does not come back, and new views are numbered after every number used before"
  (check-equal? #f (views:find loose))
  (check-equal? (+ loose 1) (views:id (views:make notes))))
