#!tuna
(import (tuna) (completion) (commands) (hooks) (layout) (views) (test-user) (test-runner))

(define (session) (views:call-with-view (layout:selected-view) completion:current-session))

(define (choices)
  (let ([s (session)])
    (test-runner:wait-until (lambda () (not (completion:session-busy? s))))
    (let ([ms (completion:session-matches s)])
      (map (lambda (k) (completion:text s (completion:matches-ref ms k))) (iota (completion:matches-count ms))))))

(define (selected)
  (let* ([s (session)] [m (completion:selected s)])
    (and m (completion:text s m))))

(define %ended '())

;; A command may pause past test-user:settle, as when it visits a file,
;; so a test that needs it done waits for its end.
(define (press-until-ended! keys command)
  (set! %ended '())
  (test-user:press! keys)
  (test-runner:wait-until (lambda () (memq command %ended))))

;; The kernel reports the end of a command quit while it waits, so a
;; quit returns what was reported, for the test to check.
(define (quit!)
  (map (lambda (c) (if (cancelled? c) 'cancelled c)) (test-runner:reports-during (lambda () (test-user:press! "C-g")))))

(hooks:add! commands:after-command (lambda (command) (set! %ended (cons command %ended))))
