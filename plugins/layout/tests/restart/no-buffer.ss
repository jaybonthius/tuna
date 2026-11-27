(import (test) (layout) (buffers) (views) (document))

(test "with no buffer at all, the layout starts as one view of a new, empty *scratch*"
  (let ([v (layout:selected-view)])
    (check-equal? (list 'layout:level '() (vector 'views:view (list (cons 'view (views:id v)) (cons 'buffer "*scratch*"))))
                  (car (document:datums (buffers:document layout:buffer))))
    (check-equal? '("*scratch*" " *layout*" " *popups*") (map buffers:name (buffers:all)))
    (check-equal? "" (document:text (buffers:document (views:buffer v))))))
