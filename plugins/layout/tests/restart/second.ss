(import (buffers))

(buffers:make "notes" "one\ntwo\nthree\n")

(import (test) (layout) (layout-split) (views) (document))

(define expected (call-with-input-file (string-append (getenv "HOME") "/expected.ss") read))

(test "after a restart the layout, the selection order, the zoom and each view's point come back"
  (check-equal? (car expected) (car (document:datums (buffers:document layout:buffer))))
  (check-equal? (cadr expected) (map views:id (layout:selection-order)))
  (check-equal? (list (caddr expected)) (map views:id (layout:views)))
  (check-equal? 5 (views:point (layout:selected-view))))
