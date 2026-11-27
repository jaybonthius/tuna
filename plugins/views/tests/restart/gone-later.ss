(import (tuna) (test) (test-runner) (views) (buffers) (timers) (views-test session))

(define notes (views-test/session:make-notes!))
(define v (views-test/session:atom-view (views-test/session:make-host!)))

(define (names-gone? datum)
  (cond
    [(string? datum) (string=? datum "*gone*<7>")]
    [(pair? datum) (or (names-gone? (car datum)) (names-gone? (cdr datum)))]
    [else #f]))

(test "at the first idle the entries still waiting go, and the saved histories no longer name the buffer"
  (timers:set-idle! #t)
  (test-runner:wait-until (lambda () (not (names-gone? (views-test/session:saved-histories)))))
  (timers:set-idle! #f)
  (check-equal? '() (views:previous-buffers v)))
