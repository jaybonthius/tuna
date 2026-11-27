#!tuna
(import (tuna) (completion) (minibuffer) (files) (echo-area) (buffer-picker) (commands) (keys) (layout) (views)
        (buffers) (document) (test-user) (test-runner))

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
      [(cancelled? (cadr outcome)) 'quit]
      [else (raise (cadr outcome))])))

;; A quit command, and the command an action quits, end by a cancel that
;; is reported, so each test names the reports its keys cause.
(define (reports-during thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (guard (c [#t (advice-remove! report keep) (raise c)])
      (thunk))
    (advice-remove! report keep)
    (map (lambda (c)
           (cond
             [(cancelled? c) 'quit]
             [(and (format-condition? c) (irritants-condition? c))
              (apply format (condition-message c) (condition-irritants c))]
             [(message-condition? c) (condition-message c)]
             [else c]))
         (reverse reported))))

(define (press! keys) (reports-during (lambda () (test-user:press! keys))))

(define (action-prompt) (keys:reading-prompt (test-user:client)))

(define (view) (layout:selected-view))

(define (session) (views:call-with-view (view) completion:current-session))

(define (prompt) (minibuffer:current-prompt))

(define (input) (minibuffer:input (prompt)))

(define (matches s)
  (let ([ms (completion:session-matches s)])
    (map (lambda (k) (completion:matches-ref ms k)) (iota (completion:matches-count ms)))))

(define (texts) (let ([s (session)]) (map (lambda (m) (completion:text s m)) (matches s))))

(define (selected-text)
  (let* ([s (session)] [m (completion:selected s)])
    (and m (completion:text s m))))

(define (settled) (test-runner:wait-until (lambda () (let ([s (session)]) (and s (not (completion:session-busy? s)))))))

(define (names) (map buffers:name (remp (lambda (b) (buffers:internal-name? (buffers:name b))) (buffers:all))))

(define (text b)
  (let ([doc (buffers:document b)])
    (buffers:text-between doc 0 (document:length doc))))

(define (show! b) (views:set-buffer! (view) b) b)

(define (position-of b string offset)
  (let* ([t (text b)] [n (string-length string)])
    (let loop ([i 0])
      (cond
        [(> (+ i n) (string-length t)) (assertion-violation 'acting:position-of "not in the buffer" string)]
        [(string=? (substring t i (+ i n)) string)
         (document:position (buffers:document b) (+ i offset) (document:unit characters))]
        [else (loop (+ i 1))]))))

(define (at! b string offset) (views:set-point! (view) (position-of b string offset)))

;; A file read lists its folder on a job, so an action that answers one
;; ends a batch or more after its key.
(define (wait-for-file) (test-runner:wait-until (lambda () (files:path (views:buffer (view))))))

(define (prompt-text) (text (views:buffer (minibuffer:prompt-view (prompt)))))

(define (first-line b)
  (let ([t (text b)])
    (let loop ([i 0])
      (if (or (= i (string-length t)) (char=? (string-ref t i) #\newline)) (substring t 0 i) (loop (+ i 1))))))

(define (help-title)
  (let ([b (buffers:find "*Help*")])
    (and b (first-line b))))

;; A command a test file defines is named after the file, so the one a
;; read of command names must match is defined here.
(commands:define-command (show-prefix [b (buffer-picker:read-buffer "Buffer: ")])
  "Says the prefix argument and B's name."
  (echo-area:message! "~s ~a" (commands:prefix-argument) (buffers:name b)))

(keys:bind! keys:global "C-c t" run-reading)
