#!tuna
(import (tuna) (completion) (minibuffer) (commands) (keys) (layout) (views) (buffers) (document) (test-user) (test-runner))

(define-record-type (%reading %make-reading reading?)
  (sealed #t)
  (fields thunk (mutable outcome)))

(define %next #f)

;; A read pauses the task that asks, so it runs in a command of its own,
;; started by a key at the test's client as a user's command is, and the
;; test reads its outcome later.
(commands:define-command (run-reading)
  "Runs the read a test started, keeping what it returned or raised."
  (let ([r %next])
    (set! %next #f)
    (guard (c [#t (%reading-outcome-set! r (list 'raised c))])
      (%reading-outcome-set! r (list 'returned ((%reading-thunk r)))))))

(define (start! thunk)
  (let ([r (%make-reading thunk 'waiting)])
    (set! %next r)
    (test-user:press! "C-c t")
    r))

(define (waiting? r) (eq? (%reading-outcome r) 'waiting))

(define (result r)
  (let ([outcome (%reading-outcome r)])
    (cond
      [(eq? outcome 'waiting) 'waiting]
      [(eq? (car outcome) 'returned) (cadr outcome)]
      [else (raise (cadr outcome))])))

(define (session) (views:call-with-view (layout:selected-view) completion:current-session))

(define (prompt) (minibuffer:current-prompt))

(define (input) (minibuffer:input (prompt)))

(define (matches s)
  (let ([ms (completion:session-matches s)])
    (map (lambda (k) (completion:matches-ref ms k)) (iota (completion:matches-count ms)))))

(define (texts s) (map (lambda (m) (completion:text s m)) (matches s)))

(define (selected-text s)
  (let ([m (completion:selected s)])
    (and m (completion:text s m))))

(define (wait-matches s)
  (test-runner:wait-until (lambda () (not (completion:session-busy? s)))))

(define (prompt-message)
  (let ([shown (test-user:elements (test-user:screen) "minibuffer-message")])
    (and (pair? shown) (test-user:element-text (car shown)))))

(define (buffer-text b)
  (let ([doc (buffers:document b)])
    (buffers:text-between doc 0 (document:length doc))))

(keys:bind! keys:global "C-c t" run-reading)
