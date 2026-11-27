(import (tuna) (test) (test-user) (layout) (layout-split) (layout-tabs) (layout-scroll) (layout-float) (editing) (echo-area)
        (undo) (minibuffer) (completion) (buffer-picker) (status-line) (recent-views) (options) (keys)
        (layout-test model))

;; recent-views' timer would make a run depend on timing.
(options:set! recent-views:delay 1000)
(keys:bind! keys:global "s-o" recent-views:select-recent-view)

(test "random layouts of every container kind, with locked, placed and other-view parts, side parts, popups and prompts, keep the rules of selection after every operation"
  (for-each
    (lambda (seed)
      (let-values ([(checks failures failed) (layout-test/model:run (test-user:client) seed 200 30)])
        (check (> checks 10000))
        (check-equal? '() failed)
        (check-equal? 0 failures)))
    '(1 2 3)))
