#!tuna
(import (tuna) (test-runner) (minibuffer) (commands) (keys) (buffers) (document) (test-user))

(define-record-type (%reading %make-reading reading?)
  (sealed #t)
  (fields thunk (mutable outcome) (mutable task)))

(define %next #f)

;; A read pauses the task that asks, so it runs in a command of its own,
;; started by a key at the test's client as a user's command is, and the
;; test reads its outcome later.
(commands:define-command (run-reading)
  "Runs the read a test started, keeping what it returned or raised."
  (let ([r %next])
    (set! %next #f)
    (%reading-task-set! r (current-task))
    (guard (c [#t (%reading-outcome-set! r (list 'raised c))])
      (%reading-outcome-set! r (list 'returned ((%reading-thunk r)))))))

(define (start! thunk)
  (let ([r (%make-reading thunk 'waiting #f)])
    (set! %next r)
    (test-user:press! "C-c t")
    r))

(define (task r) (%reading-task r))

(define (waiting? r) (eq? (%reading-outcome r) 'waiting))

(define (result r)
  (let ([outcome (%reading-outcome r)])
    (cond
      [(eq? outcome 'waiting) 'waiting]
      [(eq? (car outcome) 'returned) (cadr outcome)]
      [else (raise (cadr outcome))])))

(define (prompt) (minibuffer:current-prompt))

(define (input) (minibuffer:input (prompt)))

(define (first-element class)
  (let ([found (test-user:elements (test-user:screen) class)])
    (and (pair? found) (car found))))

(define (bracket)
  (let ([e (first-element "minibuffer-message")])
    (and e (test-user:element-text e))))

(define (bracket-face)
  (let ([e (first-element "minibuffer-message")])
    (and e (test-user:element-attribute e "data-face"))))

(define (questions) (map test-user:element-text (test-user:elements (test-user:screen) "minibuffer-question")))

(define (echo-drawn?) (and (first-element "echo-area-message") #t))

(define (report-messages thunk)
  (map (lambda (c) (if (message-condition? c) (condition-message c) c)) (test-runner:reports-during thunk)))

(define (buffer-text b)
  (let ([doc (buffers:document b)])
    (buffers:text-between doc 0 (document:length doc))))

(define (quit! r)
  (test-user:press! "C-g")
  (guard (c [(cancelled? c) 'cancelled]) (result r)))

(keys:bind! keys:global "C-c t" run-reading)
