(import (tuna) (test) (test-runner) (test-user) (layout) (layout-split) (views) (buffers) (hooks) (jobs)
        (layout-test parts))

(define atom layout-test/parts:atom)
(define named layout-test/parts:named)

(define told '())

(hooks:add! layout:selection-changed (lambda (view previous) (set! told (cons (list view previous) told))))

(define (told-during thunk)
  (set! told '())
  (thunk)
  (reverse told))

(define (start!)
  (let ([a (views:make (named "a"))] [b (views:make (named "b"))] [c (views:make (named "c"))])
    (layout-test/parts:set-parts! (layout-split:container '((direction . row)) (atom a) (atom b) (atom c)))
    (layout:select! a)
    (test-runner:wait-for-batch)
    (values a b c)))

(jobs:define-worker (given input emit)
  (import)
  (emit input))

(test "a batch that selects another view calls the hook once, with the view selected and the one selected before"
  (let-values ([(a b c) (start!)])
    (check-equal? (list (list b a)) (told-during (lambda () (test-user:press! "C-x o"))))
    (check-equal? (list (list c b))
      (told-during (lambda () (layout:select! a) (layout:select! c) (test-runner:wait-for-batch))))))

(test "a batch that changes nothing, or ends on the view it started on, calls nothing"
  (let-values ([(a b c) (start!)])
    (check-equal? '() (told-during (lambda () (test-user:press! "C-l"))))
    (check-equal? '() (told-during (lambda () (layout:select! b) (layout:select! a) (test-runner:wait-for-batch))))))

(test "a selection a job's callback makes, with no command running, is told at the end of its batch"
  (let-values ([(a b c) (start!)])
    (let ([ended (box #f)])
      (check-equal? (list (list c a))
        (told-during
          (lambda ()
            (jobs:start given 'go (lambda (v) (layout:select! c)) (lambda (how) (set-box! ended #t)))
            (test-runner:wait-until (lambda () (unbox ended)))
            (test-runner:wait-for-batch)))))))

(test "deleting the selected view tells the view selected after it, and #f for the view that left the layout"
  (let-values ([(a b c) (start!)])
    (let ([t (told-during (lambda () (test-user:press! "C-x 0")))])
      (check-equal? (list (list (layout:selected-view) #f)) t))))
