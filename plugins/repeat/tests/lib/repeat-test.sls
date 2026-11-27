#!tuna
(import (web) (views) (buffers) (layout) (test-user))

;; An override keeps a report from standard error and from the test's
;; failure, while advice such as the echo area's still sees it.
(define (reports-during thunk)
  (let ([reported '()])
    (override-set! report (lambda (c) (set! reported (cons c reported))))
    (thunk)
    (override-remove! report)
    (reverse reported)))

;; A click as views' page script sends one in the selected view.
(define (click! button at)
  (let* ([v (layout:selected-view)] [b (views:buffer v)])
    (web:post-input! (test-user:client)
      (list (cons "type" "mouse") (cons "action" "click") (cons "button" button) (cons "clicks" 1)
            (cons "modifiers" (vector)) (cons "view" (views:id v)) (cons "showing" (views:shown-count v))
            (cons "version" (buffers:version b)) (cons "at" at)))
    (test-user:settle)))
