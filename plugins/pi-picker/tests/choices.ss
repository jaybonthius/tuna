(import (tuna) (test) (test-user) (test-runner) (tables) (commands) (buffers) (views) (layout) (completion) (completion-list)
        (minibuffer) (pi) (chat) (pi-chat) (pi-picker) (test-pi) (pi-picking))

(define chat (pi-picking:started (getenv "HOME")))

(define f (pi-picking:fake chat))

(define (ref r key) (let ([p (assoc key r)]) (and p (cdr p))))

(define (last-ref type key) (let ([r (test-pi:last-request f type)]) (and r (ref r key))))

(define (requested? type) (test-runner:wait-until (lambda () (test-pi:last-request f type))))

(define (working!) (test-pi:set-state! f '(("isStreaming" . #t))) (test-pi:say! f (test-pi:event "agent_start")) (test-runner:wait-until (lambda () (pi:chat-working? chat))))

(define (settled!) (test-pi:set-state! f '()) (test-pi:say! f (test-pi:event "agent_settled" '("aborted" . #f))) (test-runner:wait-until (lambda () (not (pi:chat-working? chat)))))

(chat:show! chat)

(test-pi:answer! f "get_fork_messages"
  (lambda (r) '(("messages" . #((("entryId" . "u1") ("text" . "First\nmessage")) (("entryId" . "u2") ("text" . "Second")))))))

(test-pi:answer! f "fork" (lambda (r) `(("text" . ,(if (equal? (ref r "entryId") "u1") "First\nmessage" "Second")) ("cancelled" . #f))))

(test "pi-picker:fork reads one of your messages, newest first, each by its first line, and forks there, that message in the prompt"
  (test-user:press! "C-c p f")
  (pi-picking:settled)
  (check-equal? '("Second" "First") (pi-picking:texts))
  (test-user:type! "first")
  (pi-picking:settled)
  (test-user:press! "RET")
  (test-runner:wait-until (lambda () (equal? "u1" (last-ref "fork" "entryId"))))
  (test-runner:wait-until (lambda () (equal? "First\nmessage" (pi-picking:prompt-text chat))))
  (chat:set-prompt! chat ""))

(test "while Pi works, forking asks first"
  (working!)
  (test-user:press! "C-c p f")
  (pi-picking:settled)
  (test-user:press! "RET")
  (check-equal? "Pi is working; stop it and fork? (y or n) " (pi-picking:asking))
  (let ([before (length (test-pi:requests f))])
    (test-user:press! "n")
    (check-equal? #f (member "fork" (list-tail (test-pi:request-types f) before))))
  (settled!))

(test "/fork takes what follows it as /resume does, and alone reads, even when a candidate's text is empty"
  (test-user:type! "/fork Second")
  (test-user:press! "RET")
  (test-runner:wait-until (lambda () (equal? "u2" (last-ref "fork" "entryId"))))
  (test-runner:wait-until (lambda () (equal? "Second" (pi-picking:prompt-text chat))))
  (chat:set-prompt! chat "")
  (test-pi:answer! f "get_fork_messages"
    (lambda (r) '(("messages" . #((("entryId" . "u1") ("text" . "\nhidden first line")) (("entryId" . "u2") ("text" . "Second")))))))
  (let ([before (length (test-pi:requests f))])
    (test-user:type! "/fork")
    (test-user:press! "RET")
    (pi-picking:settled)
    (check-equal? '("Second" "") (pi-picking:texts))
    (check-equal? '(quit) (pi-picking:press! "C-g"))
    (check-equal? #f (member "fork" (list-tail (test-pi:request-types f) before))))
  (chat:set-prompt! chat ""))

(test-pi:answer! f "get_available_models"
  (lambda (r) '(("models" . #((("id" . "m1") ("name" . "One") ("provider" . "p") ("contextWindow" . 1000) ("reasoning" . #f))
                              (("id" . "fake-model") ("name" . "Fake Model") ("provider" . "fake") ("contextWindow" . 200000) ("reasoning" . #t))
                              (("id" . "m2") ("name" . "Two") ("provider" . "q") ("contextWindow" . 500) ("reasoning" . #t)))))))

(test-pi:answer! f "set_model" (lambda (r) `(("id" . ,(ref r "modelId")) ("name" . ,(ref r "modelId")) ("provider" . ,(ref r "provider")))))

(test "C-c C-m reads the chat's model, each as provider/id with its name and context window, the current one first"
  (test-user:press! "C-c C-m")
  (pi-picking:settled)
  (check-equal? '(("fake/fake-model" (shadow . "Fake Model") (shadow . "200k tokens")) ("p/m1" (shadow . "One") (shadow . "1k tokens"))
                  ("q/m2" (shadow . "Two") (shadow . "500 tokens")))
                (pi-picking:rows))
  (test-user:type! "q/")
  (pi-picking:settled)
  (test-user:press! "RET")
  (test-runner:wait-until (lambda () (equal? "m2" (last-ref "set_model" "modelId"))))
  (check-equal? "q" (last-ref "set_model" "provider")))

(test "/model with a model's provider/id sets it at once; other text starts the read with it; alone, it reads"
  (test-user:type! "/model p/m1")
  (test-user:press! "RET")
  (test-runner:wait-until (lambda () (equal? "m1" (last-ref "set_model" "modelId"))))
  (check-equal? #f (pi-picking:session))
  (test-user:type! "/model fa")
  (test-user:press! "RET")
  (pi-picking:settled)
  (check-equal? '("fa" ("fake/fake-model")) (list (minibuffer:input (minibuffer:current-prompt)) (pi-picking:texts)))
  (test-user:press! "RET")
  (test-runner:wait-until (lambda () (equal? "fake-model" (last-ref "set_model" "modelId"))))
  (test-user:type! "/model")
  (test-user:press! "RET")
  (pi-picking:settled)
  (check-equal? '("" 3) (list (minibuffer:input (minibuffer:current-prompt)) (length (pi-picking:texts))))
  (check-equal? '(quit) (pi-picking:press! "C-g")))

(test "pi-picker:select-thinking-level reads the model's levels in Pi's order, the current one first; /thinking takes a level"
  (test-pi:answer! f "get_available_thinking_levels" (lambda (r) '(("levels" . #("off" "low" "medium" "high")))))
  (test-user:press! "C-c p t")
  (pi-picking:settled)
  (check-equal? '("medium" "off" "low" "high") (pi-picking:texts))
  (test-user:type! "hi")
  (pi-picking:settled)
  (test-user:press! "RET")
  (test-runner:wait-until (lambda () (equal? "high" (pi:chat-thinking-level chat))))
  (check-equal? "high" (last-ref "set_thinking_level" "level"))
  (test-user:type! "/thinking low")
  (test-user:press! "RET")
  (test-runner:wait-until (lambda () (equal? "low" (last-ref "set_thinking_level" "level"))))
  (check-equal? #f (pi-picking:session)))

(test "pi-picker:run-command reads one of Pi's commands, grouped, with the first line of each description, then its arguments, and sends it"
  (test-pi:answer! f "get_commands"
    (lambda (r) '(("commands" . #((("name" . "review") ("description" . "Review the diff\nin detail") ("source" . "extension"))
                                  (("name" . "skill:tdd") ("description" . "Test first") ("source" . "skill"))
                                  (("name" . "fix-tests") ("description" . "Fix failing tests") ("source" . "prompt")))))))
  (settled!)
  (test-runner:wait-until (lambda () (= 3 (length (pi:chat-commands chat)))))
  (test-user:press! "C-c p c")
  (pi-picking:settled)
  (check-equal? '(("skill:tdd" (shadow . "Test first")) ("fix-tests" (shadow . "Fix failing tests")) ("review" (shadow . "Review the diff")))
                (pi-picking:rows))
  (check-equal? '("Skills" "Prompt templates" "Extension commands") (pi-picking:titles))
  (test-user:type! "fix")
  (pi-picking:settled)
  (test-user:press! "RET")
  (check-equal? "Arguments for /fix-tests (empty for none): " (pi-picking:asking))
  (test-user:type! "the parser")
  (test-user:press! "RET")
  (test-runner:wait-until (lambda () (equal? "/fix-tests the parser" (last-ref "prompt" "message"))))
  (test-user:press! "C-c p c")
  (pi-picking:settled)
  (test-user:press! "RET")
  (check-equal? "Arguments for /skill:tdd (empty for none): " (pi-picking:asking))
  (test-user:press! "RET")
  (test-runner:wait-until (lambda () (equal? "/skill:tdd" (last-ref "prompt" "message")))))

(test "the commands that act on a chat refuse outside one, and each checks what code passes it"
  (layout:switch-to-buffer (buffers:make "elsewhere" ""))
  (check-equal? '("not in a Pi chat") (pi-picking:press! "C-c p t"))
  (check-equal? "not a session" (pi-picking:violation (lambda () (pi-picker:resume 'session))))
  (chat:show! chat)
  (check-equal? "not an entry id" (pi-picking:violation (lambda () (pi-picker:fork 'u1))))
  (check-equal? "not one of Pi's commands" (pi-picking:violation (lambda () (pi-picker:run-command "review"))))
  (check-equal? "not a model" (pi-picking:violation (lambda () (pi-picker:select-model "p/m1"))))
  (check-equal? "not a string" (pi-picking:violation (lambda () (pi-picker:select-thinking-level 'high)))))

(test "the commands that act on one chat are marked for pi-chat's mode, so M-x offers them only in a chat; resume works anywhere"
  (check-equal? '(#f #t #t #t #t)
    (map (lambda (c) (and (memq 'pi-chat:mode (or (tables:ref commands:command-modes c #f) '())) #t))
         (list pi-picker:resume pi-picker:fork pi-picker:select-model pi-picker:select-thinking-level pi-picker:run-command))))
