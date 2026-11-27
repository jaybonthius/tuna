(import (tuna) (test) (test-user) (layout) (views) (buffers) (tables) (status-line) (status-line-test))

(define view status-line-test:view)

(tables:remove! status-line:segments status-line:minor-modes)
(tables:set! status-line:segments status-line:position (status-line:right 90))

(define notes (buffers:make "notes" "Buy milk.\nAnd eggs.\n"))
(views:set-buffer! (view) notes)
(views:set-point! (view) 14)

(test "the configuration hides the minor modes' lighters and moves the position to the right side"
  (check-equal? '(("status-line:modified" . "") ("status-line:buffer-name" . "notes") ("status-line:percent-position" . "65%")
                  ("status-line:region-size" . "") ("status-line:major-mode" . "Fundamental") ("status-line:position" . "L2"))
                (status-line-test:status (view))))

(import (cursors))

(test "the cursor count segment shows how many cursors a view has, as a button marked with its keymap"
  (views:add-cursor! (view) 3)
  (check-equal? "2 cursors" (status-line-test:segment-text (view) cursors:cursor-count))
  (let ([button (find (lambda (e) (equal? (symbol->string cursors:cursor-count) (test-user:element-attribute e "data-segment")))
                      (test-user:elements (status-line-test:footer (view)) "status-line-segment"))])
    (check-equal? '(button "button" "-1" #t)
      (list (car button) (test-user:element-attribute button "type") (test-user:element-attribute button "tabindex")
            (equal? (views:keymap-mark cursors:cursor-count-keys) (test-user:element-attribute button "data-keymap"))))
    (check-equal? "Click to keep only the primary cursor"
      (test-user:element-attribute (car (test-user:elements-with button "title")) "title"))))

(test "a click on the cursor count keeps only the primary cursor, and the segment shows nothing"
  (status-line-test:click! (view) 1 cursors:cursor-count-keys)
  (check-equal? 1 (length (views:cursors (view))))
  (check-equal? "" (status-line-test:segment-text (view) cursors:cursor-count)))

(test "removing a segment from the table hides it"
  (tables:remove! status-line:segments status-line:modified)
  (check-equal? #f (status-line-test:segment-text (view) status-line:modified)))

(test "views:set-option! hides one view's status line"
  (views:set-option! (view) status-line:visible #f)
  (check-equal? '() (status-line-test:status-lines)))
