(import (tuna) (test) (test-user) (layout) (views) (buffers) (tables) (status-line) (status-line-test))

(define view status-line-test:view)

(define without-minor-modes
  (map symbol->string
    (list status-line:modified status-line:buffer-name status-line:position status-line:percent-position
          status-line:region-size status-line:major-mode)))

(views:set-buffer! (view) (buffers:make "notes" "one\n"))

(tables:remove! status-line:segments status-line:minor-modes)

(test "a user's removal of a segment stays in effect when status-line reloads and places it again"
  (check-equal? without-minor-modes (status-line-test:segment-names (view)))
  (reload-modules! '((status-line)))
  (check-equal? without-minor-modes (status-line-test:segment-names (view)))
  (check-equal? 1 (length (status-line-test:status-lines))))

(test "after an unload, a new instance places the segments again under the user's removal"
  (let ([old (module-owner '(status-line))])
    (unload-owner! old)
    (load-module! '(status-line-test))
    (check-equal? #f (owner-live? old))
    (check-equal? without-minor-modes (status-line-test:segment-names (view)))))

(test "unloading the module that defines and places a segment hides it; loading it again shows it"
  (load-module! '(cursors))
  (views:add-cursor! (view) 2)
  (check-equal? "2 cursors" (status-line-test:segment-text (view) 'cursors:cursor-count))
  (unload-owner! (module-owner '(cursors)))
  (check-equal? without-minor-modes (status-line-test:segment-names (view)))
  (load-module! '(cursors))
  (check-equal? "2 cursors" (status-line-test:segment-text (view) 'cursors:cursor-count)))
