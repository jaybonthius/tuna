(import (tuna) (test) (test-user) (layout) (layout-split) (views) (buffers) (document) (commands))

(define (tree) (car (document:datums (buffers:document layout:buffer))))

(define (atom view)
  (views:view (list (cons 'view (views:id view)) (cons 'buffer (buffers:name (views:buffer view))))))

(define notes (buffers:make "notes" "one\n"))
(define a (views:make notes))
(define b (views:make notes))
(define c (views:make notes))

(let ([n (document:length (buffers:document layout:buffer))])
  (buffers:replace! layout:buffer 1 (- n 1)
    (document:from-datum (layout-split:container '((direction . row)) (atom a) (atom b) (atom c)))))

(test "the layout, its selection order and its zoom outlast an unload of layout, which unloads the container plugins too"
  (layout:select! b)
  (layout:select! c)
  (commands:run layout:zoom)
  (let ([before (tree)] [order (layout:selection-order)] [old (map module-owner '((layout) (layout-split)))])
    (unload-owner! (module-owner '(layout)))
    (check-equal? '(#f #f) (map owner-live? old))
    (load-module! '(layout-split))
    (check-equal? before (tree))
    (check-equal? order (layout:selection-order))
    (check (eq? c (layout:selected-view)))
    (check-equal? (list c) (layout:views))
    (commands:run layout:zoom)
    (check-equal? (list a b c) (layout:views))))

;; Unloading layout unloaded test-user too, and a form naming one of its
;; definitions is expanded only while it is loaded.
(load-module! '(test-user))

(test "a layout loaded again draws its clients"
  (unload-owner! (module-owner '(layout)))
  (load-module! '(test-user))
  (test-user:settle)
  (check-equal? 1 (length (test-user:elements (test-user:screen) "layout-screen"))))
