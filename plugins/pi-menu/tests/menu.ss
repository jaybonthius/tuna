(import (tuna) (test) (test-user) (test-runner) (tables) (commands) (buffers) (views) (layout) (completion) (completion-list) (echo-area) (pi) (chat)
        (pi-chat) (pi-picker) (pi-menu) (test-pi) (pi-menu-test menus))

(define home (getenv "HOME"))

(define (ref r key) (let ([p (and r (assoc key r))]) (and p (cdr p))))

(layout:switch-to-buffer (buffers:make "notes" "one\n"))

(test "the menu is the chat's: C-c C-p is a key of Pi chats, and the command is refused outside one"
  (check-equal? '("C-c C-p is undefined") (pi-menu-test/menus:press! "C-c C-p"))
  (check-equal? '("not in a Pi chat")
    (pi-menu-test/menus:reports-during (lambda () (views:call-with-view (layout:selected-view) (lambda () (commands:run pi-menu:show))))))
  (check (memq 'pi-chat:mode (tables:ref commands:command-modes pi-menu:show '()))))

(mkdir (string-append home "/src"))

(define chat (pi-menu-test/menus:started (string-append home "/src")))

(define f (pi-menu-test/menus:fake chat))

(chat:show! chat)

(test "C-c C-p shows the session, context, model and display commands, the chat's state in their descriptions, titled with the folder; C-g closes it"
  (test-user:press! "C-c C-p")
  (check-equal? (list (string-append "Pi in " home "/src")
                      '("Session" ("n" "New") ("r" "Resume") ("f" "Fork") ("C" "Clone") ("N" "Name") ("e" "Export as HTML") ("R" "Restart Pi")
                        ("Q" "Stop Pi and end the chat"))
                      '("Context" ("c" "Compact") ("a" "Pi's own compaction (on)"))
                      '("Model" ("m" "Model (Fake Model)") ("t" "Thinking level (medium)"))
                      '("Display" ("T" "Finished thinking (folded)") ("o" "Fold or unfold every block")))
                (pi-menu-test/menus:menu))
  (test-user:press! "C-g")
  (check-equal? #f (pi-menu-test/menus:menu)))

(test "the menu is computed as it shows: titled with the session's name, and a group of Pi's commands with an entry only for each kind Pi has"
  (test-pi:answer! f "get_commands"
    (lambda (r) '(("commands" . #((("name" . "review") ("description" . "Review") ("source" . "extension"))
                                  (("name" . "skill:tdd") ("description" . "Test first") ("source" . "skill"))
                                  (("name" . "audit") ("description" . "Audit") ("source" . "extension"))
                                  (("name" . "fix-tests") ("description" . "Fix") ("source" . "prompt")))))))
  (test-pi:say! f (test-pi:event "agent_settled" '("aborted" . #f)))
  (test-runner:wait-until (lambda () (= 4 (length (pi:chat-commands chat)))))
  (pi:set-session-name! chat "Parser")
  (test-user:press! "C-c C-p")
  (check-equal? "Pi: Parser" (car (pi-menu-test/menus:menu)))
  (check-equal? '("Pi's commands" ("s" "Skills (1)") ("p" "Prompt templates (1)") ("x" "Extension commands (2)"))
                (pi-menu-test/menus:group "Pi's commands")))

(test "toggles stay in the menu, which shows the new state"
  (test-user:press! "a")
  (test-runner:wait-until (lambda () (equal? "Pi no longer compacts on its own" (echo-area:current-message))))
  (check-equal? #f (ref (test-pi:last-request f "set_auto_compaction") "enabled"))
  ;; The menu shows the new state at a redraw that may come in a batch
  ;; after the one that said the message.
  (test-runner:wait-until
    (lambda () (equal? '("Context" ("c" "Compact") ("a" "Pi's own compaction (off)")) (pi-menu-test/menus:group "Context"))))
  (test-user:press! "T")
  (check-equal? '(#t "Finished thinking is shown") (list (chat:thinking-shown?) (echo-area:current-message)))
  (test-runner:wait-until
    (lambda () (equal? '("Display" ("T" "Finished thinking (shown)") ("o" "Fold or unfold every block")) (pi-menu-test/menus:group "Display"))))
  (test-user:press! "T")
  (check-equal? "Finished thinking is folded" (echo-area:current-message))
  (test-user:press! "C-g"))

(test "an entry that is not a toggle closes the menu and runs its command in the chat: Model reads with pi-picker"
  (test-pi:answer! f "get_available_models"
    (lambda (r) '(("models" . #((("id" . "m1") ("name" . "One") ("provider" . "p") ("contextWindow" . 1000) ("reasoning" . #f)))))))
  (test-user:press! "C-c C-p m")
  (test-runner:wait-until pi-menu-test/menus:session)
  (check-equal? #f (pi-menu-test/menus:menu))
  (check-equal? '("p/m1") (pi-menu-test/menus:texts))
  (check-equal? '(quit) (pi-menu-test/menus:press! "C-g")))

(test "Pi's commands are menus by source, each shown above the chat's menu, so C-g comes back to it"
  (test-user:press! "C-c C-p x")
  (check-equal? '("Pi's extension commands" (("a" "/audit") ("b" "/review"))) (pi-menu-test/menus:menu))
  (test-user:press! "C-g")
  (check-equal? "Pi: Parser" (car (pi-menu-test/menus:menu)))
  (test-user:press! "s")
  (check-equal? '("Pi's skills" (("a" "/skill:tdd"))) (pi-menu-test/menus:menu))
  (test-user:press! "C-g p")
  (check-equal? '("Pi's prompt templates" (("a" "/fix-tests"))) (pi-menu-test/menus:menu))
  (test-user:press! "C-g C-g")
  (check-equal? #f (pi-menu-test/menus:menu)))

(test "an entry of Pi's commands reads the command's arguments and sends it"
  (test-user:press! "C-c C-p x a")
  (check-equal? #f (pi-menu-test/menus:menu))
  (check-equal? "Arguments for /audit (empty for none): " (pi-menu-test/menus:asking))
  (test-user:type! "now")
  (test-user:press! "RET")
  (test-runner:wait-until (lambda () (equal? "/audit now" (ref (test-pi:last-request f "prompt") "message")))))

(test "session entries run pi-chat's and pi-picker's commands"
  (test-user:press! "C-c C-p n")
  (test-runner:wait-until (lambda () (test-pi:last-request f "new_session"))))
