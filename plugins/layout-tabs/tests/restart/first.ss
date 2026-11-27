(import (buffers))

(buffers:make "notes" "one\ntwo\nthree\n")
(buffers:make "other" "other\n")

(import (layout) (layout-split) (layout-tabs) (views) (document) (timers))

(define left (layout:selected-view))
(define right (layout-split:split-view! left (layout-split:direction row)))
(define tab (layout-tabs:add-tab! right (buffers:find "other")))
(layout:select! tab)
(layout-tabs:add-tab! tab (buffers:find "notes"))
(layout:select! left)
(timers:sleep 0)

(call-with-output-file (string-append (getenv "HOME") "/expected.ss")
  (lambda (p)
    (write (list (car (document:datums (buffers:document layout:buffer))) (views:id (layout:selected-view)) (map views:id (layout:views)))
           p)))
