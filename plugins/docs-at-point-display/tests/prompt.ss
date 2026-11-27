(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (timers) (buffers) (document) (views)
        (layout) (layout-split) (editing) (echo-area) (minibuffer) (docs-at-point) (docs-at-point-display) (signatures))

(options:set! docs-at-point:delay 0.05)

;; The claims are that nothing is asked or shown, so the check waits well
;; past docs-at-point:delay first.
(define (past-delay) (timers:sleep 0.3))

(define (docs-text) (document:text (buffers:document (buffers:find "*Docs*"))))

(define (prompt-message)
  (let ([shown (test-user:elements (test-user:screen) "minibuffer-message")])
    (and (pair? shown) (test-user:element-text (car shown)))))

(define (read-name) (minibuffer:read "Name: "))

(test-user:show! "|alpha beta\ngamma\n")

(define notes (views:buffer (layout:selected-view)))

(define notes-view (layout:selected-view))

(layout-split:split-view! notes-view (layout-split:direction row))

(test "a source local to a buffer is not asked about a prompt's text, so typing at a prompt leaves *Docs* about the code, and g still asks there"
  (buffers:with-buffer notes (hooks:add-local! docs-at-point:sources signatures:signature))
  (test-user:press! "C-f C-h .")
  (test-runner:wait-until (lambda () (and (buffers:find "*Docs*") (equal? "alpha\n(alpha x)\n" (docs-text)))))
  (signatures:start! read-name)
  (test-user:type! "a")
  (check-equal? '("a" #f #f) (list (minibuffer:input (minibuffer:current-prompt)) (echo-area:current-message) (prompt-message)))
  (test-user:type! "b")
  (past-delay)
  (check-equal? '("alpha\n(alpha x)\n" #f #f) (list (docs-text) (echo-area:current-message) (prompt-message)))
  (test-user:press! "C-g")
  (check-equal? 'quit (signatures:outcome))
  (signatures:asked!)
  (docs-at-point-display:refresh)
  (test-runner:wait-until (lambda () (pair? (signatures:asked))))
  (check-equal? (list notes-view) (signatures:asked!))
  (buffers:with-buffer notes (hooks:remove-local! docs-at-point:sources signatures:signature)))

(test "a source for every buffer is not asked about a prompt's text either"
  (hooks:add! docs-at-point:sources signatures:signature)
  (signatures:asked!)
  (signatures:start! read-name)
  (test-user:type! "ab")
  (past-delay)
  (check-equal? '("ab" () #f) (list (minibuffer:input (minibuffer:current-prompt)) (signatures:asked!) (prompt-message)))
  (test-user:press! "C-g")
  (check-equal? 'quit (signatures:outcome)))
