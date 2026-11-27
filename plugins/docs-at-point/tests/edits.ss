(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (timers) (commands) (keys) (buffers) (document) (views)
        (layout) (layout-split) (editing) (minibuffer) (docs-at-point))

(options:set! docs-at-point:delay 0.05)

(options:set! docs-at-point:after-edits-only? #t)

;; The claims are that nothing is asked, so the check waits well past
;; docs-at-point:delay first.
(define (past-delay) (timers:sleep 0.3))

(define asked '())

(define (asked!)
  (let ([a asked])
    (set! asked '())
    a))

(define (wait-for-ask) (test-runner:wait-until (lambda () (pair? asked))))

(hooks:add! docs-at-point:sources (lambda (v) (set! asked (cons v asked)) #f))

(define (view) (layout:selected-view))

(define third (buffers:make "third" "gamma delta\n"))

(commands:define-command (to-third) "Shows third." (layout:switch-to-buffer third))

(commands:define-command (insert-read) "Inserts text read at a prompt."
  (let ([s (minibuffer:read "Text: ")])
    (editing:insert! (layout:selected-view) s)))

(commands:define-command (insert-q) "Inserts q." (editing:insert! (layout:selected-view) "q"))

(keys:bind! keys:global "C-c t" to-third)

(keys:bind! keys:global "C-c i" insert-read)

(keys:bind! keys:global "C-c j" insert-q)

(test-user:show! "|alpha beta\ngamma\n")

(define notes (views:buffer (view)))

(test "with after-edits-only?, a typed character asks from the start, and a motion asks nothing"
  (test-user:type! "x")
  (wait-for-ask)
  (check-equal? (list (view)) (asked!))
  (test-user:press! "C-f")
  (past-delay)
  (check-equal? '() (asked!)))

(test "with after-edits-only?, a switch to another buffer is no edit, and typing in a buffer no ask has been made in asks"
  (test-user:press! "C-c t")
  (past-delay)
  (check-equal? (list third '()) (list (views:buffer (view)) (asked!)))
  (test-user:type! "z")
  (wait-for-ask)
  (check-equal? (list (view)) (asked!))
  (layout:switch-to-buffer notes))

(test "with after-edits-only?, a command that reads at a prompt and then edits counts as an edit, as one without a prompt does"
  (test-user:press! "C-c i")
  (test-user:type! "q")
  (asked!)
  (test-user:press! "RET")
  (wait-for-ask)
  (check-equal? (list "xaqlpha beta\ngamma\n" (list (view)))
                (list (document:text (buffers:document notes)) (asked!)))
  (test-user:press! "C-c j")
  (wait-for-ask)
  (check-equal? (list "xaqqlpha beta\ngamma\n" (list (view)))
                (list (document:text (buffers:document notes)) (asked!)))
  (options:unset! docs-at-point:after-edits-only?))

(test "an ask is about the selected view after the command: C-x o asks about the view it selects"
  (let* ([first-view (view)] [second-view (layout-split:split-view! first-view (layout-split:direction row))])
    (test-user:press! "C-f")
    (wait-for-ask)
    (asked!)
    (test-user:press! "C-x o")
    (wait-for-ask)
    (check-equal? (list second-view) (asked!))
    (test-user:press! "C-x o")
    (wait-for-ask)
    (check-equal? (list first-view) (asked!))))

(test "a local docs-at-point:delay in another buffer leaves the selected buffer's alone"
  (buffers:with-buffer third (options:set-local! docs-at-point:delay 0.05))
  (options:set! docs-at-point:delay 60)
  (test-user:press! "C-f")
  (past-delay)
  (check-equal? '() (asked!))
  (options:set! docs-at-point:delay 0.05))
