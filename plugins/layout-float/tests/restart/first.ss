(import (tuna) (test) (layout) (layout-scroll) (layout-float) (views) (buffers) (document) (layout-float-test session))

(layout-float-test/session:make-buffers!)

(let ([n (document:length (buffers:document layout:buffer))])
  (buffers:replace! layout:buffer 1 (- n 1)
    (document:from-datum
      (layout-scroll:container '() '#(views:view ((view . 301) (buffer . "notes")))
        (layout-float:container '((size . 1/3)) '#(views:view ((view . 302) (buffer . "other")))
          '#(views:view ((view . 303) (buffer . "notes") (place box 1/4 1/2))))))))
(layout-float-test/session:end-batch!)
(layout:select! (views:find 303))

(define p (layout-float:show-at! (views:find 301) 1 (buffers:find "other") 1/2 1/2))
(layout:select! p)

(test "the popup is shown and selected"
  (check-equal? 1 (length (cddr (caddr (layout-float-test/session:popups)))))
  (check-equal? p (layout:selected-view)))

(call-with-output-file (layout-float-test/session:expected-file)
  (lambda (port) (write (layout-float-test/session:tree) port))
  'replace)

(layout-float-test/session:end-batch!)
