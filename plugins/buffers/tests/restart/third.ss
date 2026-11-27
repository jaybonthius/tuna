(import (tuna) (test) (test-runner) (timers) (buffers) (buffers-test))

(buffers-test:make-all! '("a" "b"))

(test "at the first idle, the saved names no buffer took back go"
  (check-equal? '("b" "a" "c" "d") (buffers-test:saved-order))
  (timers:set-idle! #t)
  (test-runner:wait-until (lambda () (equal? '("b" "a") (buffers-test:saved-order))))
  (timers:set-idle! #f)
  (check-equal? '("b" "a") (buffers-test:names)))
