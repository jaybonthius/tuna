(import (tuna) (test) (test-user) (test-runner) (options) (tables) (keys) (buffers) (document) (views) (layout) (files)
        (projects) (kill-ring) (echo-area) (minibuffer) (processes) (pi) (chat) (pi-chat) (test-pi) (pi-chat-test))

(define home (getenv "HOME"))

(define (at path) (string-append home "/" path))

(define (write-file! path text) (call-with-output-file (at path) (lambda (p) (put-string p text)) 'replace))

(define project (at "src/tuna/"))

(for-each (lambda (f) (mkdir (at f))) '("src" "src/tuna" "src/tuna/lib"))

(write-file! "src/tuna/lib/a.txt" "one\ntwo\nthree\nfour\n")

(write-file! "src/tuna/.project" "")

(options:set! projects:extra-root-markers '(".project"))

(define file-buffer (files:visit (at "src/tuna/lib/a.txt")))

(define ref pi-chat-test:ref)

(define (current-buffer) (views:buffer (pi-chat-test:view)))

(layout:switch-to-buffer file-buffer)

(test "C-c a p shows the Pi chat used last in the buffer's project, starting one in the project's root when there is none"
  (test-user:press! "C-c a p")
  (let ([chat (car (pi:chats))])
    (check-equal? (list project "*pi: tuna*") (list (pi:chat-directory chat) (buffers:name (current-buffer))))
    (pi-chat-test:idle chat)
    (layout:switch-to-buffer file-buffer)
    (test-user:press! "C-c a p")
    (check-equal? 1 (length (pi:chats)))
    (check (eq? chat (chat:conversation-of (current-buffer))))))

(define chat (car (pi:chats)))

(define f (pi-chat-test:fake chat))

(define b (chat:buffer chat))

(test "with C-u, C-c a p always starts a new chat; stopping it kills its buffer"
  (layout:switch-to-buffer file-buffer)
  (test-user:press! "C-u C-c a p")
  (let ([second (cadr (pi:chats))])
    (check-equal? '(2 "*pi: tuna*<2>") (list (length (pi:chats)) (buffers:name (chat:buffer second))))
    (check (eq? second (car (chat:chats-for file-buffer))))
    (pi:stop! second)
    (test-user:settle)
    (check-equal? #f (buffers:find "*pi: tuna*<2>"))))

(define (send-typed! text)
  (chat:show! chat)
  (chat:set-prompt! chat text)
  (views:set-point! (pi-chat-test:view) (chat:prompt-end chat))
  (test-user:press! "RET"))

(test "Pi's terminal commands at the prompt's start run the chat's own procedures with what follows the name"
  (send-typed! "/name Refactor")
  (test-runner:wait-until (lambda () (equal? "Refactor" (pi:chat-session-name chat))))
  (check-equal? '("Refactor" "") (list (ref (test-pi:last-request f "set_session_name") "name") (pi-chat-test:prompt-text chat)))
  (send-typed! "/compact keep the API")
  (test-runner:wait-until (lambda () (test-pi:last-request f "compact")))
  (check-equal? "keep the API" (ref (test-pi:last-request f "compact") "customInstructions")))

(test "Pi's other terminal commands are refused, since sent to Pi they would reach the model as text; Pi's own commands go to Pi"
  (send-typed! "/login")
  (test-user:settle)
  (check-equal? "/login" (pi-chat-test:prompt-text chat))
  (check (member "/login is a command of Pi's terminal, which a chat cannot run" (pi-chat-test:texts "chat-notice")))
  (test-pi:answer! f "get_commands" (lambda (r) '(("commands" . #((("name" . "review") ("description" . "Review") ("source" . "extension")))))))
  (test-pi:say! f (test-pi:event "agent_settled" '("aborted" . #f)))
  (test-runner:wait-until (lambda () (pair? (pi:chat-commands chat))))
  (send-typed! "/review now")
  (test-runner:wait-until (lambda () (equal? "/review now" (ref (test-pi:last-request f "prompt") "message"))))
  (send-typed! "/")
  (test-runner:wait-until (lambda () (equal? "/" (ref (test-pi:last-request f "prompt") "message")))))

(test "a command of the table that Pi refuses puts its text back with a notice"
  (test-pi:answer! f "compact" (lambda (r) #f))
  (send-typed! "/compact now")
  (test-pi:refuse! f (test-pi:take-held! f "compact") "Already compacting")
  (test-runner:wait-until (lambda () (equal? "/compact now" (pi-chat-test:prompt-text chat))))
  (test-user:settle)
  (check (member "Pi refused the prompt: Already compacting" (pi-chat-test:texts "chat-notice")))
  (test-pi:answer! f "compact" #f)
  (chat:set-prompt! chat ""))

(test "an entry of pi-chat:slash-commands, as the docs page's /session, runs instead of sending"
  (tables:set! pi-chat:slash-commands "/session"
    (lambda (chat argument) (chat:add-to-prompt! chat (or (pi:chat-session-file chat) ""))))
  (send-typed! "/session")
  (check-equal? (pi:chat-session-file chat) (pi-chat-test:prompt-text chat))
  (tables:remove! pi-chat:slash-commands "/session")
  (chat:set-prompt! chat ""))

(test "in the conversation RET opens the file of the tool call at point at its line in another view, and f forks from your message at point"
  (test-pi:run-turn! f "u1" "a1" "First" '("Look."))
  (test-pi:append-entry! f (test-pi:entry "a2" "a1" (test-pi:assistant-message "toolUse" (test-pi:tool-block "t1" "read" '(("path" . "lib/a.txt") ("offset" . 2))))))
  (test-pi:append-entry! f (test-pi:entry "r1" "a2" (test-pi:tool-result "t1" "read" "two\nthree" #f)))
  (test-pi:run-turn! f "u2" "a3" "Second" '("Done."))
  (test-runner:wait-until (lambda () (= 5 (length (filter pi:item-entry-id (pi:chat-transcript chat))))))
  (test-user:settle)
  (pi-chat-test:at! chat "read lib")
  (test-user:press! "RET")
  (check (eq? file-buffer (current-buffer)))
  (check-equal? 2 (document:line (buffers:document file-buffer) (views:point (pi-chat-test:view))))
  (check (memq b (map views:buffer (layout:views))))
  (layout:reset-layout)
  (chat:show! chat)
  (test-pi:answer! f "fork" (lambda (r) '(("text" . "Second") ("cancelled" . #f))))
  (pi-chat-test:at! chat "Second")
  (test-user:press! "f")
  (test-runner:wait-until (lambda () (test-pi:last-request f "fork")))
  (check-equal? "u2" (ref (test-pi:last-request f "fork") "entryId"))
  (test-runner:wait-until (lambda () (equal? "Second" (pi-chat-test:prompt-text chat))))
  (chat:set-prompt! chat ""))

(test "a session command that would stop a working Pi asks first"
  (test-pi:say! f (test-pi:event "agent_start"))
  (test-runner:wait-until (lambda () (pi:chat-working? chat)))
  (chat:show! chat)
  (test-user:press! "C-c C-n")
  (check-equal? "Pi is working; stop it and start a new session? (y or n) " (pi-chat-test:minibuffer-text))
  (test-user:press! "n")
  (check-equal? #f (test-pi:last-request f "new_session"))
  (test-user:press! "C-c C-n y")
  (test-runner:wait-until (lambda () (test-pi:last-request f "new_session")))
  (check (pi:chat? chat)))

(test "copying Pi's last reply, exporting, naming the session and Pi's own compaction"
  (test-pi:answer! f "get_last_assistant_text" (lambda (r) '(("text" . "Done."))))
  (pi-chat-test:run! chat:copy-last-reply)
  (test-runner:wait-until (lambda () (let ([k (kill-ring:current)]) (and k (equal? "Done." (kill-ring:text k))))))
  (test-pi:answer! f "export_html" (lambda (r) '(("path" . "/tmp/s.html"))))
  (pi-chat-test:run! pi-chat:export-html)
  (test-runner:wait-until (lambda () (equal? "Exported the session to /tmp/s.html" (echo-area:current-message))))
  (pi-chat-test:run! pi-chat:rename-session)
  (test-user:type! "Tests")
  (test-user:press! "RET")
  (test-runner:wait-until (lambda () (equal? "Tests" (ref (test-pi:last-request f "set_session_name") "name"))))
  (pi-chat-test:run! pi-chat:toggle-auto-compaction)
  (test-runner:wait-until (lambda () (equal? "Pi no longer compacts on its own" (echo-area:current-message))))
  (check-equal? #f (ref (test-pi:last-request f "set_auto_compaction") "enabled")))

(test "the status of a chat's window: model, thinking level, activity, context, cost, queue and extensions' status texts"
  (chat:show! chat)
  (test-pi:say! f (test-pi:event "agent_start")
                (test-pi:event "queue_update" '("steering" . #("x")) '("followUp" . #()))
                (test-pi:ui-request "s1" "setStatus" '("statusKey" . "pool") '("statusText" . "1 pool(s)")))
  (test-runner:wait-until (lambda () (pair? (pi:chat-statuses chat))))
  (check-equal? "Fake Model · medium · thinking · 23% · $0.41 · 1 queued · 1 pool(s)" (chat:show-status (pi-chat-test:view)))
  (layout:switch-to-buffer file-buffer)
  (check-equal? #f (chat:show-status (pi-chat-test:view))))

(define (pi-writes! id path)
  (let ([call (test-pi:tool-block id "write" `(("path" . ,path) ("content" . "x")))])
    (test-pi:say! f (test-pi:event "message_start" (cons "message" (test-pi:assistant-message "pending")))
                  (test-pi:update `(("type" . "toolcall_start") ("contentIndex" . 0) ("id" . ,id) ("toolName" . "write"))))
    (test-runner:wait-until
      (lambda () (exists (lambda (p) (and (pi:tool-call? p) (equal? id (pi:tool-call-id p))))
                         (apply append (map pi:reply-parts (filter pi:reply? (pi:chat-transcript chat)))))))
    (test-user:settle)
    (test-pi:say! f (test-pi:update `(("type" . "toolcall_end") ("contentIndex" . 0) ("toolCall" . ,call)))
                  (test-pi:event "message_end" (cons "message" (test-pi:assistant-message "toolUse" call)))
                  (test-pi:event "tool_execution_start" (cons "toolCallId" id) '("toolName" . "write") (cons "args" `(("path" . ,path))))
                  (test-pi:event "tool_execution_end" (cons "toolCallId" id) '("toolName" . "write") '("isError" . #f)
                    '("result" . (("content" . #((("type" . "text") ("text" . "Wrote"))))))))))

(test "after Pi's edit or write tool ends, an unmodified buffer visiting the file is reverted, and a modified one is left with a notice"
  (files:not-modified file-buffer)
  (write-file! "src/tuna/lib/a.txt" "edited by Pi\n")
  (pi-writes! "e1" "lib/a.txt")
  (test-runner:wait-until (lambda () (string=? "edited by Pi\n" (pi-chat-test:text file-buffer))))
  (buffers:insert! file-buffer 1 "x")
  (write-file! "src/tuna/lib/a.txt" "edited again\n")
  (pi-writes! "e2" (at "src/tuna/lib/a.txt"))
  (chat:show! chat)
  (test-runner:wait-until
    (lambda () (member "a.txt has unsaved changes, so Pi's edit of its file is not shown in it" (pi-chat-test:texts "chat-notice"))))
  (check-equal? "xedited by Pi\n" (pi-chat-test:text file-buffer)))

(test "a chat opened on a session Pi wrote earlier takes its edits as done long ago: it reverts no buffer and warns of none"
  (test-pi:save-session! "old-session"
    (list (test-pi:entry "o1" #f (test-pi:user-message "Write a"))
          (test-pi:entry "o2" "o1" (test-pi:assistant-message "toolUse" (test-pi:tool-block "t9" "write" '(("path" . "lib/a.txt") ("content" . "y")))))
          (test-pi:entry "o3" "o2" (test-pi:tool-result "t9" "write" "Wrote" #f))))
  (let ([old (pi:start project "old-session")])
    (test-runner:wait-until (lambda () (= 2 (length (filter pi:item-entry-id (pi:chat-transcript old))))))
    (chat:show! old)
    (test-user:settle)
    (check-equal? '("xedited by Pi\n" ()) (list (pi-chat-test:text file-buffer) (pi-chat-test:texts "chat-notice")))
    (pi:stop! old)))

(test "ending the chat asks first while Pi works; killing its buffer ends Pi at once"
  (chat:show! chat)
  (check-equal? 'thinking (pi:chat-activity chat))
  (pi-chat-test:run! pi-chat:stop)
  (test-user:press! "n")
  (check-equal? 1 (length (pi:chats)))
  (let ([process (pi:chat-process chat)])
    (pi-chat-test:run! pi-chat:stop)
    (test-user:press! "y")
    (test-runner:wait-until (lambda () (processes:status process)))
    (check-equal? '(() #f -1) (list (pi:chats) (buffers:find "*pi: tuna*") (processes:status process)))))

(test "the commands that act on a Pi chat raise not in a Pi chat elsewhere"
  (layout:switch-to-buffer file-buffer)
  (check-equal? '("not in a Pi chat") (pi-chat-test:reports-during (lambda () (pi-chat-test:run! pi-chat:new-session)))))

(define other (pi-chat-test:shown-chat project))

(define g (pi-chat-test:fake other))

(define (requests-of type) (length (filter (lambda (t) (equal? t type)) (test-pi:request-types g))))

(define (typed! text)
  (chat:show! other)
  (chat:set-prompt! other text)
  (views:set-point! (pi-chat-test:view) (chat:prompt-end other))
  (test-user:press! "RET"))

(test "C-c C-k while Pi is idle changes nothing the user sees"
  (chat:show! other)
  (chat:set-prompt! other "draft")
  (views:set-point! (pi-chat-test:view) (chat:prompt-end other))
  (check-equal? '() (pi-chat-test:press! "C-c C-k"))
  (test-runner:wait-until (lambda () (test-pi:last-request g "abort")))
  (check-equal? '("draft" idle) (list (pi-chat-test:prompt-text other) (pi:chat-activity other)))
  (chat:set-prompt! other ""))

(test "cloning the session asks first while Pi works, as a new session does"
  (test-pi:say! g (test-pi:event "agent_start"))
  (test-runner:wait-until (lambda () (pi:chat-working? other)))
  (let ([clones (requests-of "clone")])
    (chat:show! other)
    (pi-chat-test:run! pi-chat:clone)
    (check-equal? "Pi is working; stop it and clone the session? (y or n) " (pi-chat-test:minibuffer-text))
    (test-user:press! "n")
    (check-equal? clones (requests-of "clone"))
    (pi-chat-test:run! pi-chat:clone)
    (test-user:press! "y")
    (test-runner:wait-until (lambda () (= (+ clones 1) (requests-of "clone")))))
  (test-pi:say! g (test-pi:event "agent_settled" '("aborted" . #f)))
  (test-runner:wait-until (lambda () (not (pi:chat-working? other)))))

(test "/name alone, /copy, /export, /clone and /new at the prompt run the chat's own commands"
  (typed! "/name")
  (check-equal? "The session has no name" (echo-area:current-message))
  (test-pi:answer! g "get_last_assistant_text" (lambda (r) '(("text" . "Copied."))))
  (typed! "/copy")
  (test-runner:wait-until (lambda () (let ([k (kill-ring:current)]) (and k (equal? "Copied." (kill-ring:text k))))))
  (test-pi:answer! g "export_html" (lambda (r) (list (cons "path" (or (ref r "outputPath") "/tmp/o.html")))))
  (typed! "/export")
  (test-runner:wait-until (lambda () (equal? "Exported the session to /tmp/o.html" (echo-area:current-message))))
  (typed! "/export /tmp/p.html")
  (test-runner:wait-until (lambda () (equal? "Exported the session to /tmp/p.html" (echo-area:current-message))))
  (let ([clones (requests-of "clone")])
    (typed! "/clone")
    (test-runner:wait-until (lambda () (= (+ clones 1) (requests-of "clone")))))
  (typed! "/new")
  (test-runner:wait-until (lambda () (test-pi:last-request g "new_session")))
  (check-equal? "" (pi-chat-test:prompt-text other)))
