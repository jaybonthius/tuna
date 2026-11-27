(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (timers) (commands) (keys) (buffers) (document) (views)
        (layout) (editing) (faces) (echo-area) (docs-at-point) (docs-at-point-display) (diagnostics) (marks))

(options:set! docs-at-point:delay 0.05)

(test-user:show! "|alpha beta gamma\n")

(define notes (views:buffer (layout:selected-view)))

;; The claim is that *Docs* does not change, so the check waits well past
;; docs-at-point:delay first.
(define (past-delay) (timers:sleep 0.3))

(define plain (buffers:make "plain" "just some text\nmore\n"))

(define (sources b) (length (buffers:with-buffer b (hooks:entries docs-at-point:sources))))

(test "diagnostics:at-point is a docs source only in buffers where the mode is on: added when it turns on there, removed when it turns off"
  (check-equal? '(0 0) (list (sources notes) (sources plain)))
  (marks:mode! notes #t)
  (check-equal? '(1 0) (list (sources notes) (sources plain)))
  (marks:mode! notes #f)
  (check-equal? 0 (sources notes)))

(test "a buffer that gets diagnostics with the mode on gets the source too"
  (let ([later (buffers:make "later" "x\n")] [source (diagnostics:make-source)])
    (buffers:with-buffer later (options:set-local! diagnostics:mode #t))
    (diagnostics:report! source later (list (diagnostics:make-diagnostic 1 2 (diagnostics:severity info) "x")))
    (check-equal? 1 (sources later))))

(commands:define-command (to-plain) "Shows plain." (layout:switch-to-buffer plain))

(keys:bind! keys:global "C-c p" to-plain)

(test "so docs at point in a buffer without a source leave *Docs* as it was"
  (define (signature v) (docs-at-point:make-doc "signature of alpha" (docs-at-point:doc-options [thing "alpha"])))
  (buffers:with-buffer notes (hooks:add-local! docs-at-point:sources signature))
  (test-user:press! "C-h .")
  (test-runner:wait-until
    (lambda () (let ([d (buffers:find "*Docs*")]) (and d (equal? "alpha\nsignature of alpha\n" (marks:text d))))))
  (layout:select! (car (views:showing notes)))
  (test-user:press! "C-c p C-f")
  (past-delay)
  (check-equal? (list plain "alpha\nsignature of alpha\n") (list (views:buffer (layout:selected-view)) (marks:text (buffers:find "*Docs*"))))
  (layout:switch-to-buffer notes)
  (buffers:with-buffer notes (hooks:remove-local! docs-at-point:sources signature)))

(test "the echo area shows a diagnostic's text at point in error, warning or success"
  (let ([source (diagnostics:make-source)])
    (marks:mode! notes #t)
    (diagnostics:report! source notes (list (marks:err notes "beta" "bad beta")))
    (views:set-point! (layout:selected-view) 1)
    (test-user:press! "M-f C-f")
    (test-runner:wait-until (lambda () (equal? "bad beta" (echo-area:current-message))))
    (check-equal? (list (marks:word notes "beta") (list (list 0 8 faces:error)))
                  (list (views:point (layout:selected-view)) (echo-area:current-spans)))))
