(import (buffers))

(buffers:make "notes" "one\n")

(import (test) (layout) (layout-split) (views))

(define expected (call-with-input-file (string-append (getenv "HOME") "/expected.ss") read))

(test "at start-up the reference view under the saved order is selected, and a saved zoom of a view gone ends"
  (check-equal? (car expected) (views:id (layout:selected-view)))
  (check-equal? (cadr expected) (map views:id (layout:selection-order)))
  (check-equal? (caddr expected) (layout:zoomed-view)))
