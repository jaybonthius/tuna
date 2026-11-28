(import (tuna) (test) (test-runner) (test-user) (web) (layout) (layout-split) (views) (buffers) (document) (keys) (commands) (tables)
        (status-line) (status-line-test))

(define view status-line-test:view)
(define click! status-line-test:click!)

(define notes (buffers:make "notes" "one\ntwo\n"))
(views:set-buffer! (view) notes)

(define (split!) (layout-split:split-view! (view) (layout-split:direction row)) (void))

(define (lock! window locked?)
  (let ([n (layout:view-node window)])
    (buffers:replace! layout:buffer (document:node-start n) (document:node-end n)
      (views:view (append `((view . ,(views:id window)) (buffer . "notes")) (if locked? '((locked . #t)) '()))))))

(test "status-line:keymap binds the middle and right buttons to its commands, and a press and drag of the left to nothing"
  (check-equal? '(("<mouse-2>" . status-line:mouse-reset-layout) ("<mouse-3>" . status-line:mouse-delete-view)
                  ("<down-mouse-1>" . keys:ignore) ("<drag-mouse-1>" . keys:ignore))
    (map (lambda (b) (cons (car b) (commands:command-name (cdr b)))) (keys:bindings status-line:keymap))))

(test "a left click on a status line selects its window through the layout's keymap; on a locked window's, nothing"
  (split!)
  (let ([windows (layout:views)])
    (check-equal? 2 (length (status-line-test:status-lines)))
    (check-equal? #f (buffers:find " *status-line*"))
    (layout:select! (car windows))
    (click! (cadr windows) 1)
    (check (eq? (view) (cadr windows)))
    (lock! (car windows) #t)
    (click! (car windows) 1)
    (check (eq? (view) (cadr windows)))
    (lock! (car windows) #f)))

(define clicked '())

(commands:define-command (note-click [event (keys:command-event)])
  "Notes where a click on a segment ran."
  (set! clicked (list (eq? (views:current) layout:screen-view)
                      (layout:part-view (views:posn-node (keys:event-end event))))))

(tables:define-table name-keys "Clicks on the name.")
(tables:define-table menu-keys "Right clicks on a segment.")

(status-line:define-segment name (show (lambda (v) (buffers:name (views:buffer v)))) (keymap name-keys))

(keys:bind! name-keys "<mouse-1>" note-click)
(keys:bind! menu-keys "<mouse-3>" note-click)

(define (state-of keymap)
  (let ([m (views:keymap-mark keymap)])
    (substring m (string-length (number->string (status-line-test:mark-number keymap))) (string-length m))))

(test "a segment's keymap comes first, and its command runs in layout:screen-view, finding its window from the clicked node"
  (tables:set! status-line:segments name (status-line:left 25))
  (let ([windows (layout:views)])
    (click! (cadr windows) 1 name-keys)
    (check-equal? (list #t (cadr windows)) clicked)))

(test "a segment whose keymap binds the left button is clickable; one binding only the right, and the line, carry no state"
  (check-equal? '(" clickable" "" "") (map state-of (list name-keys menu-keys status-line:keymap))))

(test "a key the segment's keymap does not bind falls through to status-line:keymap: the middle button keeps only the clicked window"
  (let ([windows (layout:views)])
    (click! (cadr windows) 2 name-keys)
    (check-equal? (list 1 #t) (list (length (layout:views)) (eq? (view) (cadr windows))))
    (tables:remove! status-line:segments name)))

(test "a click whose window was deleted since its line was drawn is stale"
  (split!)
  (let* ([two (layout:views)] [drawn (buffers:version layout:buffer)] [gone (cadr two)])
    (test-user:settle)
    (let ([item (status-line-test:mouse-item gone "click" 3 drawn (list status-line:keymap))])
      (layout:delete-part! (layout:view-node gone))
      (check-equal? '("Stale click: what was clicked is gone")
        (map condition-message (test-runner:reports-during (lambda () (web:post-input! (test-user:client) item) (test-user:settle))))))
    (check-equal? 1 (length (layout:views)))))

(test "the right button deletes the clicked window and the middle keeps only it, whichever is selected"
  (split!)
  (split!)
  (let ([three (layout:views)])
    (check-equal? 3 (length (status-line-test:status-lines)))
    (layout:select! (car three))
    (click! (caddr three) 3)
    (check-equal? (list 2 #t #f) (list (length (layout:views)) (eq? (view) (car three)) (memq (caddr three) (layout:views))))
    (click! (cadr three) 2)
    (check-equal? (list 1 #t) (list (length (layout:views)) (eq? (view) (cadr three))))))

(test "the right button deletes neither the only window of its level, even in a container holding only it, nor a locked one"
  (let ([only (view)])
    (click! only 3)
    (check-equal? (list 1 #t) (list (length (layout:views)) (eq? (view) only)))
    (commands:run layout:part-mode)
    (commands:run layout-split:wrap-in-row)
    (commands:run layout:part-mode-leave)
    (check-equal? 'layout-split:container
      (document:node-kind (document:enclosing (buffers:document layout:buffer) (document:node-start (layout:view-node (view))))))
    (click! (view) 3)
    (check-equal? (list 1 #t) (list (length (layout:views)) (eq? (view) only)))
    (split!)
    (let ([two (layout:views)])
      (layout:select! (car two))
      (lock! (cadr two) #t)
      (click! (cadr two) 3)
      (check-equal? (list 2 #t) (list (length (layout:views)) (eq? (view) (car two))))
      (check-equal? "the last view that is not locked" (layout:deletion-refusal (layout:view-node (car two))))
      (click! (car two) 3)
      (check-equal? (list 2 #t) (list (length (layout:views)) (eq? (view) (car two)))))))

(define (click-text! view button)
  (for-each
    (lambda (action)
      (web:post-input! (test-user:client)
        (list (cons "type" "mouse") (cons "action" action) (cons "button" button) (cons "clicks" 1)
              (cons "modifiers" '#()) (cons "at" 1) (cons "count" 0) (cons "view" (views:id view))
              (cons "version" (buffers:version (views:buffer view))) (cons "showing" (views:shown-count view)))))
    '("down" "click"))
  (test-user:settle))

(test "the line's commands do nothing for a click that is not on the layout's drawing, and raise for what is not an event"
  (split!)
  (keys:bind! keys:global "<mouse-3>" status-line:mouse-delete-view)
  (keys:bind! keys:global "<mouse-2>" status-line:mouse-reset-layout)
  (let* ([count (length (layout:views))] [ran 0] [note (lambda (next event) (set! ran (+ ran 1)) (next event))])
    (advice-add! status-line:mouse-delete-view note)
    (advice-add! status-line:mouse-reset-layout note)
    (click-text! (view) 3)
    (click-text! (view) 2)
    (advice-remove! status-line:mouse-delete-view note)
    (advice-remove! status-line:mouse-reset-layout note)
    (check-equal? (list 2 count) (list ran (length (layout:views)))))
  (check-raises (status-line-test:raised? 'status-line:mouse-delete-view "not an event") (status-line:mouse-delete-view "d"))
  (check-raises (status-line-test:raised? 'status-line:mouse-reset-layout "not an event") (status-line:mouse-reset-layout "r")))
