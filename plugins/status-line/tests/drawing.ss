(import (tuna) (test) (test-user) (layout) (layout-split) (views) (buffers) (document) (options) (tables)
        (status-line) (status-line-test))

(define view status-line-test:view)

(define (names-shown client)
  (map (lambda (s) (cdr (assoc "status-line:buffer-name" s))) (status-line-test:status-lines client)))

(define notes (buffers:make "notes" "one\ntwo\n"))

(define other (test-user:open-client))

(views:set-buffer! (view) notes)

(test "a status line is drawn after the view inside each view atom's element of the layout"
  (test-user:settle)
  (let* ([e (find (lambda (e) (equal? (number->string (document:node-start (layout:view-node (view))))
                                      (test-user:element-attribute e "data-at")))
                  (test-user:elements (test-user:screen) "layout-view"))]
         [classes (map (lambda (child) (test-user:element-attribute child "class")) (filter pair? (cddr e)))])
    (check-equal? '("status-line") (cdr (member "view" classes)))))

(test "every unlocked window has one, a part placed at an unlocked side too, and every client shows the same"
  (let ([side ((layout-split:display-at-side (layout:direction left) 40 '(columns 20)) (buffers:make "*side*" ""))])
    (layout-split:split-view! (view) (layout-split:direction row))
    (check-equal? '("*side*" "notes" "notes") (names-shown (test-user:client)))
    (layout:delete-part! (layout:view-node side))
    (check-equal? '("notes" "notes") (names-shown (test-user:client)))
    (check-equal? (status-line-test:status-lines (test-user:client)) (status-line-test:status-lines other))))

(test "a locked part has no status line, though draw gives one; a view with no atom in the layout gets #f"
  (let ([bar ((layout-split:display-at-side (layout:direction down) 50 'content '((locked . #t))) (buffers:make "*bar*" ""))])
    (check (layout:locked? (layout:view-node bar)))
    (check-equal? '("notes" "notes") (names-shown (test-user:client)))
    (check (status-line:draw bar (test-user:client)))
    (check-equal? #f (status-line:draw (views:make notes) (test-user:client)))))

(test "the parts of the popups have none"
  (let ([popup (views:make (buffers:make "*popup*" ""))])
    (buffers:replace! layout:popups-buffer 1 1 (views:view `((view . ,(views:id popup)) (buffer . "*popup*"))))
    (check-equal? 2 (length (status-line-test:status-lines)))))

(test "status-line:visible is read in the view: a buffer's local value hides every view of the buffer's, a view's own one view's"
  (buffers:with-buffer notes (options:set-local! status-line:visible #f))
  (check-equal? '() (status-line-test:status-lines))
  (buffers:with-buffer notes (options:unset-local! status-line:visible))
  (check-equal? 2 (length (status-line-test:status-lines)))
  (views:set-option! (view) status-line:visible #f)
  (check-equal? 1 (length (status-line-test:status-lines)))
  (check (status-line:draw (view) (test-user:client)))
  (views:set-option! (view) status-line:visible #t))
