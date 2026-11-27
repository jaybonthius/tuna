(import (tuna) (test) (test-user) (test-runner) (layout) (layout-split) (recent-views) (minibuffer) (echo-area)
        (commands) (views) (buffers) (document) (keys) (options) (timers))

(options:set! recent-views:delay 0.1)
(keys:bind! keys:global "s-o" recent-views:select-recent-view)

(commands:define-command (ask-question) "Asks a question in the minibuffer." (minibuffer:read "Q: "))

(keys:bind! keys:global "C-c q" ask-question)

;; The selected view gets its tick when recent-views' timer fires, which
;; is the only timer started after the plugins loaded.
(define loaded-timers (timers:live))

(define (pause!) (test-runner:wait-until (lambda () (for-all (lambda (t) (memq t loaded-timers)) (timers:live)))))

(define (atom view)
  (views:view (list (cons 'view (views:id view)) (cons 'buffer (buffers:name (views:buffer view))))))

(test "s-o from a prompt picks among the views of the level the user was in"
  (let ([a (views:make (buffers:make "a" ""))])
    (let ([n (document:length (buffers:document layout:buffer))])
      (buffers:replace! layout:buffer 1 (- n 1) (document:from-datum (atom a))))
    (layout:select! a)
    (test-user:press! "C-x 3 C-x o")
    (let ([b (layout:selected-view)])
      (pause!)
      (test-user:press! "C-c q")
      (check (minibuffer:current-prompt))
      (test-user:press! "s-o")
      (check (eq? b (layout:selected-view)))
      (commands:run minibuffer:abort))))
