(import (tuna) (test) (layout) (layout-scroll) (layout-float) (views) (layout-float-test session))

(layout-float-test/session:make-buffers!)

(test "the layout comes back as it was, with the view selected last in it; the popup does not"
  (check-equal? (call-with-input-file (layout-float-test/session:expected-file) read) (layout-float-test/session:tree))
  (check-equal? '(layout:popups-root ()) (layout-float-test/session:popups))
  (check-equal? 303 (views:id (layout:selected-view)))
  (check-equal? '(301 302 303) (map views:id (layout:views))))
