#!tuna
(import (tuna) (pi) (chat) (chat-picker) (completion) (keys) (layout) (views) (buffers) (document) (test-pi) (test-user)
        (test-runner))

(define (fake chat) (test-pi:fake (pi:chat-process chat)))

;; A chat asks Pi four things as it starts, and a test speaks for Pi only
;; once their answers are taken in.
(define (started directory)
  (let ([chat (pi:start directory)])
    (test-runner:wait-until (lambda () (>= (length (test-pi:requests (fake chat))) 4)))
    (test-runner:wait-until (lambda () (eq? (pi:chat-activity chat) 'idle)))
    chat))

(define (view) (layout:selected-view))

(define (session) (views:call-with-view (view) completion:current-session))

(define (settled) (test-runner:wait-until (lambda () (let ([s (session)]) (and s (not (completion:session-busy? s)))))))

(define (matches s)
  (let ([ms (completion:session-matches s)])
    (map (lambda (k) (completion:matches-ref ms k)) (iota (completion:matches-count ms)))))

(define (texts) (let ([s (session)]) (map (lambda (m) (completion:text s m)) (matches s))))

(define (rows) (let ([s (session)]) (map (lambda (m) (cons (completion:text s m) (completion:annotation s m))) (matches s))))

(define (text b)
  (let ([doc (buffers:document b)])
    (buffers:text-between doc 0 (document:length doc))))

(define (prompt-text chat)
  (buffers:text-between (buffers:document (chat:buffer chat)) (chat:prompt-start chat) (chat:prompt-end chat)))

(define (message-of c)
  (cond
    [(cancelled? c) 'quit]
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

(define (violation thunk)
  (guard (c [(assertion-violation? c) (condition-message c)])
    (views:call-with-view (view) thunk)
    'no-violation))

(keys:bind! keys:global "C-c a s" chat-picker:switch-to-chat)
(keys:bind! keys:global "C-c a o" chat-picker:add-region-to)
