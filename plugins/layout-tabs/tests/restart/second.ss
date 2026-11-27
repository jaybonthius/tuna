(import (buffers))

(buffers:make "notes" "one\ntwo\nthree\n")
(buffers:make "other" "other\n")

(import (test) (layout) (layout-split) (layout-tabs) (views) (document))

(define expected (call-with-input-file (string-append (getenv "HOME") "/expected.ss") read))

(test "after a restart the tabs come back, each showing the tab it showed, with the selected view"
  (check-equal? (car expected) (car (document:datums (buffers:document layout:buffer))))
  (check-equal? (cadr expected) (views:id (layout:selected-view)))
  (check-equal? (caddr expected) (map views:id (layout:views))))
