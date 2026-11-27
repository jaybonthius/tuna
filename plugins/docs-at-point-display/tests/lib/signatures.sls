#!tuna
(import (tuna) (buffers) (document) (views) (editing) (faces) (commands) (keys) (test-user) (docs-at-point))

(define %asked '())

(define (asked) %asked)

(define (asked!)
  (let ([a %asked])
    (set! %asked '())
    a))

(define (word-at view)
  (let* ([b (views:buffer view)] [p (views:point view)]
         [s (editing:forward-word-position b (min (+ p 1) (- (document:length (buffers:document b)) 1)) -1)]
         [e (editing:forward-word-position b s 1)])
    (document:text (buffers:document b) s e)))

(define (signature view)
  (set! %asked (cons view %asked))
  (let ([word (word-at view)])
    (docs-at-point:make-doc (string-append "(" word " x)")
      (docs-at-point:doc-options [thing word] [spans (list (list (+ 2 (string-length word)) (+ 3 (string-length word)) faces:highlight))]))))

(define (described view)
  (docs-at-point:make-doc (string-append "Takes **" (word-at view) "**.")
    (docs-at-point:doc-options [markdown] [thing (word-at view)])))

(define %next #f)

(define %outcome #f)

;; A read pauses the task that asks, so it runs in a command of its own,
;; started by a key at the test's client as a user's command is.
(commands:define-command (run-command)
  "Runs the command a test started, keeping whether it was quit."
  (let ([thunk %next])
    (set! %next #f)
    (set! %outcome 'waiting)
    (guard (c [(cancelled? c) (set! %outcome 'quit)])
      (thunk)
      (set! %outcome 'done))))

(define (start! thunk)
  (set! %next thunk)
  (test-user:press! "C-c t"))

(define (outcome) %outcome)

(keys:bind! keys:global "C-c t" run-command)
