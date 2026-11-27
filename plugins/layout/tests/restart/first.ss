(import (buffers))

(buffers:make "notes" "one\ntwo\nthree\n")

(import (layout) (layout-split) (views) (document) (commands) (timers))

(define split (layout-split:split-view! (layout:selected-view) (layout-split:direction row)))
(views:set-point! split 5)
(layout:select! split)
(commands:run layout:zoom)

;; Views saves the views the layout's atoms name, as it learns of them at a
;; batch's end.
(timers:sleep 0)

(call-with-output-file (string-append (getenv "HOME") "/expected.ss")
  (lambda (p)
    (write (list (car (document:datums (buffers:document layout:buffer))) (map views:id (layout:selection-order)) (views:id split))
           p)))
