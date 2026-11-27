(import (tuna) (test) (test-user) (options) (keys) (commands) (buffers) (views) (ask) (files) (chat) (fake-talks) (fake-agents)
        (chat-test))

(define home (getenv "HOME"))

(define (drafts) (fake-agents:echo-drafts))

(define e (fake-talks:start 'echo home))

(define e-session (fake-talks:talk-session e))

(commands:define-command (kill-chat) "Kills the current buffer." (buffers:kill! (views:buffer (views:current))))

(keys:bind! keys:global "C-c k" kill-chat)

(test "an unsent prompt is saved data, by the chat's session"
  (chat:show! e)
  (test-user:type! "unsent")
  (check-equal? (list (cons e-session "unsent")) (drafts)))

(test "killing a chat with an unsent prompt asks nothing: the draft is kept, then the source's kill runs"
  (let ([asked '()] [b (chat:buffer e)])
    (options:set! ask:y-or-n-reader (lambda (question) (set! asked (cons question asked)) #f))
    (check-equal? #t (buffers:modified? b))
    (test-user:press! "C-c k")
    (check-equal? '() asked)
    (check-equal? #f (buffers:live? b))
    (check-equal? #f (memq e ((fake-talks:live 'echo))))
    (check-equal? "unsent" (cdr (assoc e-session (drafts))))
    (options:unset! ask:y-or-n-reader)))

(define other (fake-talks:start 'echo home))

(test "a draft is its session's, so it outlives its chat: another chat's prompt edits leave it"
  (chat:show! other)
  (test-user:type! "x")
  (check-equal? '("x" "unsent") (map cdr (drafts))))

(test "the prompt keeps its text when its chat moves to another session, so the draft moves, and the session left keeps no copy"
  (let ([left (fake-talks:talk-session other)])
    (fake-talks:move! other "s-new")
    (test-user:settle)
    (check-equal? "x\n" (chat-test:shown other))
    (check-equal? '(#f ("s-new" . "x")) (list (assoc left (drafts)) (assoc "s-new" (drafts))))
    (chat:set-prompt! other "")
    (test-user:settle)
    (check-equal? '("unsent") (map cdr (drafts)))))

(test "a reload of chat keeps the draft moving with its chat"
  (chat:show! other)
  (test-user:type! "kept")
  (reload-modules! '((chat)))
  (fake-talks:move! other "s-after")
  (test-user:settle)
  (check-equal? '(#f ("s-after" . "kept")) (list (assoc "s-new" (drafts)) (assoc "s-after" (drafts)))))

(test "a chat killed in the batch it moves into a session that keeps a draft saves that draft before its own prompt's text"
  (let ([b (chat:buffer other)])
    (fake-talks:move! other e-session)
    (buffers:kill! b)
    (test-user:settle)
    (check-equal? '("unsent\nkept" #f) (list (cdr (assoc e-session (drafts))) (assoc "s-after" (drafts))))))

(test "opening a session again puts its draft back in the prompt, before the text there"
  (let ([third (fake-talks:start 'echo home)])
    (chat:show! third)
    (test-user:type! "typed")
    (fake-talks:move! third e-session)
    (test-user:settle)
    (check-equal? "unsent\nkept\ntyped\n" (chat-test:shown third))
    (check-equal? "unsent\nkept\ntyped" (cdr (assoc e-session (drafts))))))
