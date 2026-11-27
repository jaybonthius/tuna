#!tuna
(import (status-line) (layout) (views) (keys) (commands) (haml) (tables))

(define (show-cursor-count view)
  (let ([n (length (views:cursors view))])
    (and (> n 1)
         (haml (:span ([title "Click to keep only the primary cursor"]) n " cursors")))))

(commands:define-command (keep-primary-cursor [event (keys:command-event)])
  "Removes every cursor but the primary one from the view whose status line was clicked."
  (let ([view (layout:part-view (views:posn-node (keys:event-end event)))])
    (for-each (lambda (cursor) (views:remove-cursor! view cursor)) (cdr (views:cursors view)))))

(tables:define-table cursor-count-keys "Clicks on the cursor count.")

(status-line:define-segment cursor-count
  (show show-cursor-count)
  (keymap cursor-count-keys))

(keys:bind! cursor-count-keys "<mouse-1>" keep-primary-cursor)

(tables:set! status-line:segments cursor-count (status-line:right 10))
