#!tuna
(import (tuna) (pi) (hooks) (test-pi) (test-runner))

(define (describe item)
  (cond
    [(pi:user-message? item) (list 'user (pi:item-key item) (pi:item-entry-id item) (pi:user-message-text item))]
    [(pi:reply? item)
     (list 'reply (pi:item-key item) (pi:item-entry-id item) (pi:reply-stop item)
           (map (lambda (p)
                  (cond
                    [(pi:text? p) (list 'text (pi:text-string p))]
                    [(pi:thinking? p) (list 'thinking (pi:thinking-string p))]
                    [else (list 'tool (pi:tool-call-name p) (pi:tool-call-state p) (pi:tool-call-output p))]))
                (pi:reply-parts item)))]
    [(pi:notice? item) (list 'notice (pi:notice-level item) (pi:notice-text item))]
    [(pi:summary? item) (list 'summary (pi:summary-kind item) (pi:summary-text item))]
    [(pi:extension-message? item) (list 'extension (pi:extension-message-type item) (pi:extension-message-text item))]
    [(pi:shell-command? item) (list 'shell (pi:shell-command-line item))]
    [else item]))

(define (fake chat) (test-pi:fake (pi:chat-process chat)))

(define (transcript chat) (map describe (pi:chat-transcript chat)))

(define (saved-items chat) (filter pi:item-entry-id (pi:chat-transcript chat)))

(define (idle chat) (test-runner:wait-until (lambda () (eq? (pi:chat-activity chat) 'idle))))

;; A chat asks Pi four things as it starts, and a test speaks for Pi only
;; once their answers are taken in.
(define (started directory . session-id)
  (let ([chat (apply pi:start directory session-id)])
    (answered (fake chat) 4)
    (idle chat)
    chat))

;; What Pi is told pauses the task that tells it, so a test tells Pi in a
;; task of its own when it must answer for Pi meanwhile. A refusal is the
;; task's value, as a task that ends by a raise is reported.
(define (in-task thunk)
  (spawn-task
    (lambda (restore)
      (guard (c [(pi:refused? c) (list 'refused (condition-message c))])
        (thunk)))))

(define (done? t) (eq? (task-state t) 'done))

(define (outcome t) (test-runner:join t))

(define (refusal thunk) (outcome (in-task thunk)))

(define (message-of c)
  (cond
    [(and (format-condition? c) (irritants-condition? c)) (apply format (condition-message c) (condition-irritants c))]
    [(message-condition? c) (condition-message c)]
    [else c]))

(define (reports-during thunk)
  (map message-of (test-runner:reports-during thunk)))

(define (reports-after thunk count)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (guard (c [#t (advice-remove! report keep) (raise c)])
      (thunk)
      (test-runner:wait-until (lambda () (>= (length reported) count))))
    (advice-remove! report keep)
    (map message-of (reverse reported))))

(define (violation thunk)
  (guard (c [(assertion-violation? c) (list (condition-who c) (condition-message c))])
    (thunk)
    'no-violation))

;; Pi's output reaches a chat in order, so once the hook has seen a text
;; set after some events, the chat has taken those events in.
(define %editor-texts '())

(define %barriers 0)

(define (barrier f)
  (set! %barriers (+ %barriers 1))
  (let ([text (format "barrier ~a" %barriers)])
    (test-pi:say! f (test-pi:ui-request text "set_editor_text" (cons "text" text)))
    (test-runner:wait-until (lambda () (member text %editor-texts)))))

;; Pi's answers reach a chat in order with what it says, so a test that
;; speaks for Pi waits until the answers to what it was asked are taken in.
(define (answered f count)
  (test-runner:wait-until (lambda () (>= (length (test-pi:requests f)) count)))
  (barrier f))

(define (editor-texts) (remp (lambda (t) (and (> (string-length t) 8) (string=? "barrier " (substring t 0 8)))) (reverse %editor-texts)))

(define %activities '())

(define (activities!)
  (let ([seen (reverse %activities)])
    (set! %activities '())
    seen))

(hooks:add! pi:activity-changed (lambda (chat old new) (set! %activities (cons new %activities))))

(hooks:add! pi:editor-text-requested (lambda (chat text) (set! %editor-texts (cons text %editor-texts))))
