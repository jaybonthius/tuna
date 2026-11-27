#!tuna
(import (tuna) (chat) (commands) (keys) (layout) (views) (buffers) (document) (test-user) (test-runner))

(define (view) (layout:selected-view))

(define (current) (views:call-with-view (view) chat:current))

(define (run! command) (views:call-with-view (view) (lambda () (commands:run command))))

(define (text b)
  (let ([doc (buffers:document b)])
    (buffers:text-between doc 0 (document:length doc))))

(define (shown c) (text (chat:buffer c)))

(define (prompt-text c)
  (buffers:text-between (buffers:document (chat:buffer c)) (chat:prompt-start c) (chat:prompt-end c)))

(define (message-of c)
  (cond
    [(cancelled? c) 'quit]
    [(and (format-condition? c) (irritants-condition? c)) (apply format (condition-message c) (condition-irritants c))]
    [(message-condition? c) (condition-message c)]
    [else c]))

(define (reports-during thunk)
  (map message-of (test-runner:reports-during thunk)))

(define (press! keys) (reports-during (lambda () (test-user:press! keys))))

(define (raised thunk)
  (guard (c [(not (cancelled? c)) (message-of c)])
    (thunk)
    'nothing))

(define (position-of b string offset)
  (let* ([t (text b)] [n (string-length string)])
    (let loop ([i 0])
      (cond
        [(> (+ i n) (string-length t)) (assertion-violation 'chat-test:position-of "not in the buffer" string)]
        [(string=? (substring t i (+ i n)) string) (document:position (buffers:document b) (+ i offset) (document:unit characters))]
        [else (loop (+ i 1))]))))

(define (at! b string) (views:set-point! (view) (position-of b string 0)))

(define (element class)
  (let ([found (test-user:elements (test-user:screen) class)])
    (and (pair? found) (car found))))

(define (waiting)
  (let ([e (element "chat-waiting")])
    (and e (list (test-user:element-text e) (test-user:element-attribute e "title")))))

(keys:bind! keys:global "C-c a t" chat:toggle)
(keys:bind! keys:global "C-c a r" chat:add-region)
(keys:bind! keys:global "C-c a d" chat:next-question)
