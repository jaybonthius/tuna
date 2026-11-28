(import (tuna) (test) (test-user) (test-runner) (tables) (commands) (buffers) (views) (layout) (completion) (completion-list) (echo-area) (pi) (chat)
        (transient) (pi-chat) (pi-picker) (pi-menu) (test-pi) (pi-menu-test menus))

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

(test "a click on the chat's status segment, marked clickable, shows the menu"
  (let ([segment (find (lambda (el) (equal? (test-user:element-text el) (chat:show-status (layout:selected-view))))
                       (test-user:elements (test-user:screen) "status-line-segment"))])
    (let ([mark (test-user:element-attribute segment "data-keymap")])
      (check (string=? " clickable" (substring mark (- (string-length mark) 10) (string-length mark)))))
    (test-user:click-element! segment))
  (check-equal? (string-append "Pi in " home "/src") (car (pi-menu-test/menus:menu)))
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

(define (entry-node key)
  (find (lambda (n)
          (let ([entries (test-user:elements n "transient-entry")])
            (and (= 1 (length entries)) (= 1 (length (test-user:elements n "node")))
                 (equal? key (test-user:element-text (car (test-user:elements (car entries) "transient-key")))))))
        (test-user:elements (test-user:screen) "node")))

(test "a click on an entry, marked clickable, runs it as its key does"
  (test-user:press! "C-c C-p")
  (let ([entry (entry-node "T")])
    (check-equal? "clickable" (test-user:element-attribute entry "data-click"))
    (test-user:click-element! entry))
  (check-equal? #t (chat:thinking-shown?))
  (test-user:press! "T C-g")
  (check-equal? '(#f #f) (list (chat:thinking-shown?) (pi-menu-test/menus:menu))))

(test "an entry added with transient:add! shows in the menu"
  (transient:add! pi-menu:menu "Mine" (transient:command "z" "Fold all" chat:toggle-all-blocks))
  (test-user:press! "C-c C-p")
  (check-equal? '("Mine" ("z" "Fold all")) (pi-menu-test/menus:group "Mine"))
  (test-user:press! "C-g"))

(test "past 61 commands of one kind the menu leaves the rest out"
  (test-pi:answer! f "get_commands"
    (lambda (r)
      (list (cons "commands" (list->vector (map (lambda (i) (list (cons "name" (format "c~2,'0d" i)) '("description" . "C") '("source" . "extension")))
                                                (iota 62)))))))
  (test-pi:say! f (test-pi:event "agent_settled" '("aborted" . #f)))
  (test-runner:wait-until (lambda () (= 62 (length (pi:chat-commands chat)))))
  (test-user:press! "C-c C-p x")
  (let ([entries (cadr (pi-menu-test/menus:menu))])
    (check-equal? '(61 ("Z" "/c60")) (list (length entries) (car (last-pair entries)))))
  (test-user:press! "C-g C-g"))

(test "session entries run pi-chat's and pi-picker's commands"
  (test-user:press! "C-c C-p n")
  (test-runner:wait-until (lambda () (test-pi:last-request f "new_session"))))
