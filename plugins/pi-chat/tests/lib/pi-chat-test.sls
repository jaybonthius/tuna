#!tuna
(import (tuna) (pi) (chat) (pi-chat) (keys) (commands) (layout) (views) (buffers) (document) (test-pi) (test-user) (test-runner))

(define (fake chat) (test-pi:fake (pi:chat-process chat)))

(define (idle chat) (test-runner:wait-until (lambda () (eq? (pi:chat-activity chat) 'idle))))

;; A chat asks Pi four things as it starts, and a test speaks for Pi only
;; once their answers are taken in.
(define (started directory . session-id)
  (let ([chat (apply pi:start directory session-id)])
    (test-runner:wait-until (lambda () (>= (length (test-pi:requests (fake chat))) 4)))
    (idle chat)
    chat))

(define (shown-chat directory)
  (let ([chat (started directory)])
    (chat:show! chat)
    (test-user:settle)
    chat))

(define (view) (layout:selected-view))

;; A command that asks runs as a key would run it, in a task, so the test
;; can answer it.
(define (run! command) (spawn-task (lambda (restore) (views:call-with-view (view) (lambda () (commands:run command))))) (test-user:settle))

(define (minibuffer-text)
  (let ([b (buffers:find " *Minibuf*")])
    (and b (let ([t (text b)]) (substring t 0 (- (string-length t) 1))))))

(define (text b)
  (let ([doc (buffers:document b)])
    (buffers:text-between doc 0 (document:length doc))))

(define (shown chat) (text (chat:buffer chat)))

(define (prompt-text chat)
  (buffers:text-between (buffers:document (chat:buffer chat)) (chat:prompt-start chat) (chat:prompt-end chat)))

(define (position-of b string)
  (let* ([t (text b)] [n (string-length string)])
    (let loop ([i 0])
      (cond
        [(> (+ i n) (string-length t)) (assertion-violation 'pi-chat-test:position-of "not in the buffer" string)]
        [(string=? (substring t i (+ i n)) string) (document:position (buffers:document b) i (document:unit characters))]
        [else (loop (+ i 1))]))))

(define (at! chat string) (views:set-point! (view) (position-of (chat:buffer chat) string)))

(define (elements class) (test-user:elements (test-user:screen) class))

(define (texts class) (map test-user:element-text (elements class)))

(define (lines element) (map test-user:element-text (test-user:elements element "line")))

(define (wait-for-elements class count)
  (test-runner:wait-until (lambda () (= count (length (elements class))))))

(define (message-of c)
  (cond
    [(cancelled? c) 'quit]
    [(and (format-condition? c) (irritants-condition? c)) (apply format (condition-message c) (condition-irritants c))]
    [(message-condition? c) (condition-message c)]
    [else c]))

(define (reports-during thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (guard (c [#t (advice-remove! report keep) (raise c)])
      (thunk))
    (advice-remove! report keep)
    (map message-of (reverse reported))))

(define (press! keys) (reports-during (lambda () (test-user:press! keys))))

(define (ref object key) (let ([pair (and (pair? object) (assoc key object))]) (and pair (cdr pair))))

(keys:bind! keys:global "C-c a d" chat:next-question)

(keys:bind! keys:global "C-c a p" pi-chat:open)

(keys:bind! keys:global "C-c a t" chat:toggle)

(keys:bind! keys:global "C-c a r" chat:add-region)
