(import (tuna) (test) (buffers) (buffers-test))

(buffers-test:make-all! '("a" "b" "c" " internal"))
(buffers:move-to-front! (buffers:find "b"))

(test "before the restart, b was used last"
  (check-equal? '("b" "a" "c" " internal") (buffers-test:names)))
