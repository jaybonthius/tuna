(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (timers) (commands) (keys) (buffers) (document) (views)
        (layout) (layout-split) (editing) (faces) (echo-area) (docs-at-point) (docs-at-point-display) (docs-at-point-display-test signatures))

(options:set! docs-at-point:delay 0.05)

;; The claims are that the docs do not show, so the check waits well
;; past docs-at-point:delay first.
(define (past-delay) (timers:sleep 0.3))

(define (message-is? text) (lambda () (equal? text (echo-area:current-message))))

(define (messages-text)
  (let ([b (buffers:find "*Messages*")])
    (if b (document:text (buffers:document b)) "")))

(test-user:show! "|alpha beta\ngamma\n")

(define notes (views:buffer (layout:selected-view)))

(define notes-view (layout:selected-view))

(define other-view (layout-split:split-view! notes-view (layout-split:direction row)))

(hooks:add! docs-at-point:sources docs-at-point-display-test/signatures:signature)

(test "as point rests, the echo area shows the doc as its thing, a colon and its echo, its ranges moved past the thing, and does not log it"
  (let ([logged (messages-text)])
    (test-user:press! "C-f")
    (test-runner:wait-until (message-is? "alpha: (alpha x)"))
    (check-equal? (list (list 14 15 faces:highlight)) (echo-area:current-spans))
    (check-equal? logged (messages-text))))

(test "after a command the docs show again at once, until the new ones come"
  (options:set! docs-at-point:delay 0.5)
  (test-user:press! "M-f C-f")
  (check-equal? "alpha: (alpha x)" (echo-area:current-message))
  (options:set! docs-at-point:delay 0.05)
  (test-runner:wait-until (message-is? "beta: (beta x)")))

(test "docs never cover a message"
  (echo-area:message! "Saved")
  (docs-at-point-display-test/signatures:asked!)
  (docs-at-point:ask-sources notes-view)
  (test-runner:wait-until (lambda () (pair? (docs-at-point-display-test/signatures:asked))))
  (test-user:settle)
  (check-equal? "Saved" (echo-area:current-message)))

(test "a doc's thing shows in its face"
  (define (faced v)
    (docs-at-point:make-doc "(total items)"
      (docs-at-point:doc-options [thing "total"] [face faces:function] [spans (list (list 7 12 faces:highlight))])))
  (hooks:remove! docs-at-point:sources docs-at-point-display-test/signatures:signature)
  (hooks:add! docs-at-point:sources faced)
  (test-user:press! "C-b")
  (test-runner:wait-until (message-is? "total: (total items)"))
  (check-equal? (list (list 0 5 faces:function) (list 14 19 faces:highlight)) (echo-area:current-spans))
  (hooks:remove! docs-at-point:sources faced))

(test "docs show a line each; a doc whose echo is not its text shows no ranges, and one with no echo is left out; echo-lines cuts the rest with an ellipsis"
  (define (two v)
    (list (docs-at-point:make-doc "first line" (docs-at-point:doc-options [thing "one"] [echo "short"] [spans (list (list 0 5 faces:highlight))]))
          (docs-at-point:make-doc "unseen" (docs-at-point:doc-options [echo #f]))
          (docs-at-point:make-doc "second")))
  (hooks:add! docs-at-point:sources two)
  (test-user:press! "C-a")
  (test-runner:wait-until (message-is? "one: short\nsecond"))
  (check-equal? '() (echo-area:current-spans))
  (options:set! docs-at-point-display:echo-lines 1)
  (test-user:press! "C-e")
  (test-runner:wait-until (message-is? "one: short…"))
  (options:unset! docs-at-point-display:echo-lines)
  (hooks:remove! docs-at-point:sources two))

(test "when the sources answer with no docs, the echo area's docs go"
  (let ([answered? #f])
    (define (none v) (set! answered? #t) #f)
    (hooks:add! docs-at-point:sources docs-at-point-display-test/signatures:signature)
    (test-user:press! "C-a")
    (test-runner:wait-until (message-is? "alpha: (alpha x)"))
    (hooks:remove! docs-at-point:sources docs-at-point-display-test/signatures:signature)
    (hooks:add! docs-at-point:sources none)
    (test-user:press! "C-f")
    (test-runner:wait-until (lambda () answered?))
    (test-user:settle)
    (check-equal? #f (echo-area:current-message))
    (hooks:remove! docs-at-point:sources none)))

(test "docs cleared while the user is away from their place show again on the way back, though nothing asks again there"
  (let ([plain (buffers:make "plain" "x\n")])
    (hooks:add! docs-at-point:sources docs-at-point-display-test/signatures:signature)
    (test-user:press! "C-a")
    (test-runner:wait-until (message-is? "alpha: (alpha x)"))
    (views:set-buffer! other-view plain)
    (buffers:with-buffer plain (options:set-local! docs-at-point:mode #f))
    (test-user:press! "C-x o")
    (past-delay)
    (test-user:press! "C-f")
    (past-delay)
    (check-equal? (list plain #f) (list (views:buffer (layout:selected-view)) (echo-area:current-message)))
    (docs-at-point-display-test/signatures:asked!)
    (test-user:press! "C-x o")
    (past-delay)
    (check-equal? (list notes '() "alpha: (alpha x)")
                  (list (views:buffer (layout:selected-view)) (docs-at-point-display-test/signatures:asked!) (echo-area:current-message)))))

(test "docs show again after a command only where the mode is on in their buffer"
  (buffers:with-buffer notes (options:set-local! docs-at-point:mode #f))
  (test-user:press! "C-e")
  (past-delay)
  (check-equal? #f (echo-area:current-message))
  (buffers:with-buffer notes (options:unset-local! docs-at-point:mode))
  (test-user:press! "C-a")
  (test-runner:wait-until (message-is? "alpha: (alpha x)")))

(test "docs show again after a command only in their view while it shows their buffer"
  (let ([elsewhere (buffers:make "elsewhere" "no sources here\n")])
    (hooks:remove! docs-at-point:sources docs-at-point-display-test/signatures:signature)
    (buffers:with-buffer notes (hooks:add-local! docs-at-point:sources docs-at-point-display-test/signatures:signature))
    (test-user:press! "C-f")
    (test-runner:wait-until (message-is? "alpha: (alpha x)"))
    (views:set-buffer! notes-view elsewhere)
    (test-user:press! "C-f")
    (past-delay)
    (check-equal? (list elsewhere #f) (list (views:buffer (layout:selected-view)) (echo-area:current-message)))
    (views:set-buffer! notes-view notes)))

(test "once the buffer's sources are gone, the next changed place clears its docs, and they do not show again"
  (test-user:press! "C-a")
  (test-runner:wait-until (message-is? "alpha: (alpha x)"))
  (buffers:with-buffer notes (hooks:remove-local! docs-at-point:sources docs-at-point-display-test/signatures:signature))
  (test-user:press! "C-f")
  (past-delay)
  (test-user:press! "C-f")
  (past-delay)
  (check-equal? #f (echo-area:current-message)))

(test "a late answer about a view the user has left shows nowhere in the echo area"
  (let ([held #f] [answered? #f])
    (define (slow v)
      (suspend (lambda (resume) (set! held resume)))
      (set! answered? #t)
      (docs-at-point:make-doc "slow"))
    (hooks:add! docs-at-point:sources slow)
    (test-user:press! "C-a")
    (test-runner:wait-until (lambda () held))
    (layout:select! other-view)
    (test-user:press! "C-f")
    (held void)
    (test-runner:wait-until (lambda () answered?))
    (test-user:settle)
    (check-equal? #f (echo-area:current-message))
    (hooks:remove! docs-at-point:sources slow)))
