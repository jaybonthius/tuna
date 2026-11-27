(import (tuna) (test) (test-user) (test-runner) (buffers) (views) (modes) (processes) (pi) (chat) (pi-chat) (test-pi)
        (pi-chat-test))

(define home (getenv "HOME"))

(define chat (pi-chat-test:shown-chat home))

(define f (pi-chat-test:fake chat))

(define b (chat:buffer chat))

(define ref pi-chat-test:ref)

(test "a Pi chat is a buffer of pi-chat's mode, named after its folder, and the buffer of Pi's process"
  (check-equal? (string-append "*pi: " (path-last home) "*") (buffers:name b))
  (check-equal? 'pi-chat:mode (modes:major-mode b))
  (check (eq? chat (chat:conversation-of b)))
  (check (eq? b (processes:buffer (pi:chat-process chat))))
  (check (eq? chat (views:call-with-view (pi-chat-test:view) pi-chat:current-chat))))

(test "RET sends the prompt with pi:send!, its text moving at once into pi-chat:prompt-history"
  (test-pi:hold! f "prompt")
  (test-user:type! "Fix it")
  (test-user:press! "RET")
  (let ([r (test-pi:take-held! f "prompt")])
    (check-equal? '("Fix it" "steer") (list (ref r "message") (ref r "streamingBehavior")))
    (check-equal? '("\n" ("Fix it")) (list (pi-chat-test:shown chat) (pi-chat:prompt-history)))
    (test-pi:respond! f r '(("disposition" . "started")))))

(test "M-RET follows up with pi:follow-up!, and a text Pi refuses comes back before what was typed since, the chat saying why"
  (test-user:type! "Then")
  (test-user:press! "S-RET")
  (test-user:type! "test")
  (test-user:press! "M-RET")
  (let ([r (test-pi:take-held! f "prompt")])
    (check-equal? '("Then\ntest" "followUp") (list (ref r "message") (ref r "streamingBehavior")))
    (test-user:type! "more")
    (test-pi:refuse! f r "Cannot submit a prompt while compaction is in progress"))
  (test-runner:wait-until (lambda () (equal? "Then\ntest\nmore" (pi-chat-test:prompt-text chat))))
  (test-user:settle)
  (check-equal? '("Pi refused the prompt: Cannot submit a prompt while compaction is in progress") (pi-chat-test:texts "chat-notice"))
  (check-equal? '("Then\ntest" "Fix it") (pi-chat:prompt-history))
  (test-pi:answer! f "prompt" #f))

(test "Pi takes no text into a running turn: C-RET refuses while Pi works, and sends as RET does while it is idle"
  (test-pi:say! f (test-pi:event "agent_start"))
  (test-runner:wait-until (lambda () (pi:chat-working? chat)))
  (check-equal? '("Pi takes no text into a running turn") (pi-chat-test:press! "C-RET"))
  (check-equal? "Then\ntest\nmore" (pi-chat-test:prompt-text chat))
  (test-pi:say! f (test-pi:event "agent_settled" '("aborted" . #f)))
  (test-runner:wait-until (lambda () (not (pi:chat-working? chat))))
  (test-pi:hold! f "prompt")
  (test-user:press! "C-RET")
  (let ([r (test-pi:take-held! f "prompt")])
    (check-equal? '("Then\ntest\nmore" "steer") (list (ref r "message") (ref r "streamingBehavior")))
    (test-pi:respond! f r '(("disposition" . "started"))))
  (test-pi:answer! f "prompt" #f))

(test "Pi's queue shows under the conversation; M-<up> takes it back, steers first, and C-c C-k stops Pi and does the same"
  (test-pi:answer! f "clear_queue" (lambda (r) '(("steering" . #("a")) ("followUp" . #("b")))))
  (test-pi:say! f (test-pi:event "queue_update" '("steering" . #("a")) '("followUp" . #("b"))))
  (pi-chat-test:wait-for-elements "chat-queued" 2)
  (check-equal? '("Steer a" "Follow-up b") (pi-chat-test:texts "chat-queued"))
  (test-user:press! "M->")
  (test-user:press! "M-<up>")
  (test-runner:wait-until (lambda () (equal? "a\nb" (pi-chat-test:prompt-text chat))))
  (test-user:press! "C-c C-k")
  (test-runner:wait-until (lambda () (equal? "a\nb\na\nb" (pi-chat-test:prompt-text chat))))
  (check-equal? '("clear_queue" "clear_queue" "abort") (list-tail (test-pi:request-types f) (- (length (test-pi:requests f)) 3))))

(test "an extension may set the prompt's text"
  (test-pi:say! f (test-pi:ui-request "e1" "set_editor_text" '("text" . "/review")))
  (test-runner:wait-until (lambda () (equal? "/review" (pi-chat-test:prompt-text chat)))))

(test "an unsent prompt is kept in pi-chat:drafts by the chat's session, and moves with the chat to another session"
  (check-equal? (list (cons (pi:chat-session-id chat) "/review")) (pi-chat:drafts))
  (let ([before (pi:chat-session-id chat)])
    (test-pi:set-state! f '(("sessionId" . "s-new")))
    (pi:new-session! chat)
    (test-runner:wait-until (lambda () (equal? "s-new" (pi:chat-session-id chat))))
    (test-user:settle)
    (check-equal? '(#f ("s-new" . "/review")) (list (assoc before (pi-chat:drafts)) (assoc "s-new" (pi-chat:drafts))))))

(test "what is typed in a question's field stays when pi reloads, and pi-chat finds the chat's buffer again"
  (test-pi:say! f (test-pi:ui-request "d6" "input" '("title" . "Why")))
  (pi-chat-test:wait-for-elements "chat-field" 1)
  (test-user:press! "C-c a d")
  (test-user:type! "Because")
  (reload-modules! '((pi)))
  (let ([chat (car (pi:chats))])
    (pi-chat-test:idle chat)
    (test-runner:wait-until (lambda () (= 1 (length (pi-chat-test:elements "chat-field")))))
    (check-equal? '("Because") (pi-chat-test:texts "chat-field"))
    (check (eq? b (chat:buffer chat)))))

(test "killing a chat's buffer ends Pi at once and ends the chat"
  (let* ([chat (car (pi:chats))] [process (pi:chat-process chat)])
    (buffers:kill! (chat:buffer chat))
    (test-runner:wait-until (lambda () (processes:status process)))
    (check-equal? '(() -1) (list (pi:chats) (processes:status process)))))
