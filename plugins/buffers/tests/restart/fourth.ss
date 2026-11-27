(import (tuna) (test) (test-runner) (timers) (buffers) (buffers-test))

(buffers-test:make-all! '("a"))

(test "after two restarts the saved order names no buffer that is gone"
  (timers:set-idle! #t)
  (test-runner:wait-until (lambda () (equal? '("a") (buffers-test:saved-order))))
  (timers:set-idle! #f)
  (check-equal? '("a") (buffers-test:names)))
