(import (tuna) (views) (buffers) (views-test session))

(define notes (views-test/session:make-notes!))
(define v (views-test/session:atom-view (views-test/session:make-host!)))
(define loose (views:make notes))

(call-with-output-file (views-test/session:home-file "loose") (lambda (p) (write (views:id loose) p)) 'replace)
(views:set-point! v 12)
(views:set-mark! v 9)
(views:add-cursor! v 2)
(views:fold! v 18 22)
(views:narrow! v 1 25)
(views:scroll-to! v 9 (views:align top))
(views:set-option! v views:wrap-lines #f)

(views-test/session:end-batch!)
