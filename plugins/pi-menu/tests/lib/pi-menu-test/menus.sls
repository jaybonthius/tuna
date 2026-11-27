#!tuna
(import (tuna) (pi) (completion) (layout) (views) (buffers) (document) (test-pi) (test-user) (test-runner))

(define (fake chat) (test-pi:fake (pi:chat-process chat)))

;; A chat asks Pi four things as it starts, and a test speaks for Pi only
;; once their answers are taken in.
(define (started directory)
  (let ([chat (pi:start directory)])
    (test-runner:wait-until (lambda () (>= (length (test-pi:requests (fake chat))) 4)))
    (test-runner:wait-until (lambda () (eq? (pi:chat-activity chat) 'idle)))
    chat))

(define (%first element class)
  (let ([found (test-user:elements element class)])
    (and (pair? found) (car found))))

(define (%entry e)
  (list (test-user:element-text (%first e "transient-key")) (test-user:element-text (%first e "ui-label"))))

(define (%group g)
  (let ([heading (%first g "transient-heading")] [entries (map %entry (test-user:elements g "transient-entry"))])
    (if heading (cons (test-user:element-text heading) entries) entries)))

(define (menu)
  (let ([shown (%first (test-user:screen) "transient-menu")])
    (and shown
         (let ([title (%first shown "transient-title")] [groups (map %group (test-user:elements shown "transient-group"))])
           (if title (cons (test-user:element-text title) groups) groups)))))

(define (group name) (find (lambda (g) (and (pair? g) (equal? (car g) name))) (menu)))

(define (session) (views:call-with-view (layout:selected-view) completion:current-session))

(define (texts)
  (let* ([s (session)] [ms (completion:session-matches s)])
    (test-runner:wait-until (lambda () (not (completion:session-busy? s))))
    (map (lambda (k) (completion:text s (completion:matches-ref ms k))) (iota (completion:matches-count ms)))))

(define (asking)
  (let ([b (buffers:find " *Minibuf*")])
    (and b (let* ([doc (buffers:document b)] [t (buffers:text-between doc 0 (document:length doc))])
             (substring t 0 (- (string-length t) 1))))))

(define (reports-during thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (guard (c [#t (advice-remove! report keep) (raise c)])
      (thunk))
    (advice-remove! report keep)
    (map (lambda (c) (cond [(cancelled? c) 'quit] [(message-condition? c) (condition-message c)] [else c])) (reverse reported))))

(define (press! keys) (reports-during (lambda () (test-user:press! keys))))
