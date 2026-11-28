(import (tuna) (test) (test-runner) (layout) (layout-float) (views) (buffers) (document) (test-user))

(define (atom view . attributes)
  (views:view (cons* (cons 'view (views:id view)) (cons 'buffer (buffers:name (views:buffer view))) attributes)))

(define a (buffers:make (buffers:free-name "a") "a\n"))
(define va (views:make a))

(let ([n (document:length (buffers:document layout:buffer))])
  (buffers:replace! layout:buffer 1 (- n 1) (document:from-datum (atom va))))
(layout:select! va)

(define p (layout-float:show-at! va 1 a 1/2 1/2))
(define (popup-atom) (document:token (buffers:document layout:popups-buffer) 2))

(test "popups live in a tree of their own: the part procedures take its nodes, but a popup is not a view of the layout"
  (check-equal? p (layout:part-view (popup-atom)))
  (check (layout:locked? (popup-atom)))
  (check-equal? (buffers:name a) (layout:part-title (popup-atom)))
  (check-equal? #f (layout:view-node p)))

(test "popup-node finds a popup's atom, as view-node a view's in the layout"
  (check-equal? 2 (document:node-start (layout:popup-node p)))
  (check-equal? #f (layout:popup-node va))
  (check-raises (test-runner:raised-with 'layout:popup-node "not a view") (layout:popup-node 'p)))

(test "set-part-attribute! sets and removes an attribute of a part of either tree, keeping its others"
  (layout:set-part-attribute! (layout:popup-node p) 'title "pop")
  (check-equal? "pop" (layout:part-title (layout:popup-node p)))
  (check (layout:locked? (layout:popup-node p)))
  (layout:set-part-attribute! (layout:popup-node p) 'title #f)
  (check-equal? (buffers:name a) (layout:part-title (layout:popup-node p)))
  (layout:set-part-attribute! (layout:view-node va) 'other-view #t)
  (check-equal? #t (document:node-attribute (layout:view-node va) 'other-view))
  (layout:set-part-attribute! (layout:view-node va) 'other-view #f)
  (check-equal? 'none (document:node-attribute (layout:view-node va) 'other-view 'none))
  (check-raises (test-runner:raised-with 'layout:set-part-attribute! "not a symbol") (layout:set-part-attribute! (layout:view-node va) "title" "x"))
  (check-raises (test-runner:raised-with 'layout:set-part-attribute! "not a node") (layout:set-part-attribute! 'part 'title "x")))

(test "a popup is locked, so the user's commands refuse to delete it"
  (layout:select! p)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (test-user:press! "C-x 0")
    (advice-remove! report keep)
    (check-equal? '((layout:delete-view "a locked part")) (map (lambda (c) (list (condition-who c) (condition-message c))) reported)))
  (layout:select! va))

(test "an edit may move a popup within the popups buffer, but no edit may give a view in one tree to the other"
  (check (guard (c [(buffers:refused? c) #t])
           (buffers:replace! layout:popups-buffer 1 1 (layout-float:container '() (atom va)))
           #f))
  (check (guard (c [(buffers:refused? c) #t])
           (let ([n (document:length (buffers:document layout:buffer))])
             (buffers:replace! layout:buffer (- n 1) (- n 1) (atom p)))
           #f)))
