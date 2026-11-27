#!tuna
(import (web) (views) (buffers) (layout) (test-user))

;; A mouse item as views' page script sends one for the selected view.
(define (mouse! action button modifiers at)
  (let* ([v (layout:selected-view)] [b (views:buffer v)])
    (web:post-input! (test-user:client)
      (list (cons "type" "mouse") (cons "action" action) (cons "button" button) (cons "clicks" 1)
            (cons "modifiers" (list->vector modifiers)) (cons "view" (views:id v)) (cons "showing" (views:shown-count v))
            (cons "version" (buffers:version b)) (cons "at" at) (cons "report" 0)))
    (test-user:settle)))
