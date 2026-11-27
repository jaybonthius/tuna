(import (tuna) (test) (buffers) (buffers-test))

(buffers-test:make-all! '("c" "d" "a" "b"))

(test "buffers made again take their saved places among those not used since, and one the saved order does not name goes after them"
  (check-equal? '("b" "a" "c" "d") (buffers-test:names)))
