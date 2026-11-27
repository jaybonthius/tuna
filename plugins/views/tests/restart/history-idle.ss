(import (tuna) (test) (test-runner) (views) (buffers) (timers) (views-test session))

(define notes (views-test/session:make-notes!))
(define v (views-test/session:atom-view (views-test/session:make-host!)))

(test "a batch that changes a history writes the views, not the histories; idling writes them"
  (views:set-point! v 5)
  (views-test/session:end-batch!)
  (test-runner:wait-until (lambda () (views-test/session:saved-views)))
  (let ([histories (views-test/session:saved-histories)] [views (views-test/session:saved-views)])
    (views:set-buffer! v (buffers:make "late" "late\n"))
    (views-test/session:end-batch!)
    (test-runner:wait-until (lambda () (not (equal? views (views-test/session:saved-views)))))
    (check-equal? histories (views-test/session:saved-histories))
    (timers:set-idle! #t)
    (test-runner:wait-until (lambda () (not (equal? histories (views-test/session:saved-histories)))))
    (timers:set-idle! #f)))
