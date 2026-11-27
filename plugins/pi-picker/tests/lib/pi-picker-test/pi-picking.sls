#!tuna
(import (tuna) (pi) (chat) (pi-picker) (completion) (keys) (layout) (views) (buffers) (document) (json) (test-pi) (test-user)
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

(define (titles) (let ([s (session)]) (map (lambda (m) (completion:title s m)) (matches s))))

(define (text b)
  (let ([doc (buffers:document b)])
    (buffers:text-between doc 0 (document:length doc))))

(define (prompt-text chat)
  (buffers:text-between (buffers:document (chat:buffer chat)) (chat:prompt-start chat) (chat:prompt-end chat)))

(define (asking)
  (let ([b (buffers:find " *Minibuf*")])
    (and b (let ([t (text b)]) (substring t 0 (- (string-length t) 1))))))

(define (reports-during thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (guard (c [#t (advice-remove! report keep) (raise c)])
      (thunk))
    (advice-remove! report keep)
    (map (lambda (c) (cond [(cancelled? c) 'quit] [(message-condition? c) (condition-message c)] [else c])) (reverse reported))))

(define (press! keys) (reports-during (lambda () (test-user:press! keys))))

(define (violation thunk)
  (guard (c [(assertion-violation? c) (condition-message c)])
    (views:call-with-view (view) thunk)
    'no-violation))

(define (write-session! folder id lines date)
  (let ([path (string-append folder "/" id ".jsonl")])
    (call-with-output-file path
      (lambda (p) (for-each (lambda (l) (put-string p (json->string l)) (newline p)) lines))
      'replace)
    (system (string-append "touch -d '" date "' " path))
    path))

(keys:bind! keys:global "C-c p r" pi-picker:resume)
(keys:bind! keys:global "C-c p f" pi-picker:fork)
(keys:bind! keys:global "C-c p t" pi-picker:select-thinking-level)
(keys:bind! keys:global "C-c p c" pi-picker:run-command)
