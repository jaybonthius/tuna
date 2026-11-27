(import (tuna) (test) (test-user) (test-runner) (options) (tables) (commands) (keys) (buffers) (document) (views) (layout)
        (layout-split) (modes) (files) (kill-ring) (status-line) (chat) (chat-test fake-talks) (chat-test fake-agents) (chat-test))

(define home (getenv "HOME"))

(define (syntax-error? message)
  (lambda (c) (and (syntax-violation? c) (string=? message (condition-message c)))))

(test "a source names every clause chat needs; a missing one, one given twice and question clauses in part are syntax errors"
  (for-each
    (lambda (module message) (check-raises (syntax-error? message) (load-module! (list 'chat-test 'bad-source module))))
    '(no-conversation title-twice some-questions)
    '("the conversation? clause is required" "clause given twice" "the question clauses are given all or none")))

(test "a value no loaded source accepts is not a chat"
  (check-equal? "not a chat" (chat-test:raised (lambda () (chat:buffer 'x))))
  (check-equal? "not a chat" (chat-test:raised (lambda () (chat:show! "talk")))))

(define e (chat-test/fake-talks:start 'echo home))

(define p (chat-test/fake-talks:start 'parrot home))

(test "each source's chats share chat's buffer, keys and segments; RET sends the prompt into the source's history"
  (chat:show! e)
  (check-equal? (string-append "*echo: " (path-last home) "*") (buffers:name (views:buffer (chat-test:view))))
  (check (eq? e (chat-test:current)))
  (check-equal? 'chat-test/fake-agents:mode (modes:major-mode (views:buffer (chat-test:view))))
  (test-user:type! "hello")
  (test-user:press! "RET")
  (check-equal? '((send . "hello")) (chat-test/fake-talks:talk-sent e))
  (check-equal? '("hello") (chat-test/fake-agents:echo-history))
  (check-equal? "\n" (chat-test:shown e)))

(test "C-RET takes the text into a running turn when the source can; with no turn running it sends as RET does"
  (chat-test/fake-talks:working! e #t)
  (test-user:type! "now")
  (test-user:press! "C-RET")
  (chat-test/fake-talks:working! e #f)
  (test-user:type! "idle")
  (test-user:press! "C-RET")
  (check-equal? '((send . "idle") (send-now . "now") (send . "hello")) (chat-test/fake-talks:talk-sent e)))

(test "a source without send-now refuses C-RET while its agent works, and the text stays; idle, C-RET sends"
  (chat:show! p)
  (chat-test/fake-talks:working! p #t)
  (test-user:type! "wait")
  (check-equal? '("Parrot takes no text into a running turn") (chat-test:press! "C-RET"))
  (check-equal? "wait\n" (chat-test:shown p))
  (chat-test/fake-talks:working! p #f)
  (test-user:press! "C-RET")
  (check-equal? '((send . "wait")) (chat-test/fake-talks:talk-sent p))
  (check-equal? '("wait") (chat-test/fake-agents:parrot-history))
  (check-equal? '("idle" "now" "hello") (chat-test/fake-agents:echo-history)))

(test "without a follow-up clause M-RET sends as RET does"
  (test-user:type! "later")
  (test-user:press! "M-RET")
  (check-equal? '((send . "later") (send . "wait")) (chat-test/fake-talks:talk-sent p)))

(test "the status segment shows the source's status, else its activity"
  (check-equal? "Parrot · idle" (chat:show-status (chat-test:view)))
  (chat:show! e)
  (check-equal? "idle" (chat:show-status (chat-test:view))))

(test "one waiting segment counts the questions of every source, in every window"
  (chat-test/fake-talks:ask! p "p1" "Proceed?" '(((label . "Go") (key . #f) (value . go))))
  (test-user:settle)
  (check-equal? '("Parrot asks" "Parrot waits for an answer; click to go to the question") (chat-test:waiting))
  (chat-test/fake-talks:ask! e "e1" "Allow?" '(((label . "Yes") (key . "y") (value . yes)) ((label . "No") (key . "n") (value . no))))
  (test-user:settle)
  (check-equal? '("Agents ask 2 questions" "Agents wait for an answer; click to go to the question") (chat-test:waiting)))

(test "chat:next-question goes to the oldest question; on its answers a key answers with the answer that has it"
  (test-user:press! "C-c a d")
  (check (eq? p (chat-test:current)))
  (check-equal? '("no answer on y") (chat-test:press! "y"))
  (test-user:press! "RET")
  (check-equal? '(("p1" . go)) (chat-test/fake-talks:talk-answered p))
  (check-equal? '("Echo asks" "Echo waits for an answer; click to go to the question") (chat-test:waiting))
  (test-user:press! "C-c a d")
  (check (eq? e (chat-test:current)))
  (check-equal? '("no answer on x") (chat-test:press! "x"))
  (test-user:press! "n")
  (check-equal? '(("e1" . no)) (chat-test/fake-talks:talk-answered e))
  (check-equal? #f (chat-test:waiting))
  (check-equal? '("no question waits") (chat-test:press! "C-c a d")))

(test "without a fork clause f raises; without last-reply the last reply drawn is copied, as its item text"
  (chat:show! e)
  (check-equal? '("Echo cannot fork") (chat-test:reports-during (lambda () (chat-test:run! chat:fork))))
  (check-equal? '("Echo has not replied yet") (chat-test:reports-during (lambda () (chat-test:run! chat:copy-last-reply))))
  (chat-test/fake-talks:reply! e "Done *now*")
  (test-user:settle)
  (chat-test:run! chat:copy-last-reply)
  (check-equal? "Done *now*" (kill-ring:text (kill-ring:current))))

(test "without item-text either there is nothing to copy, though the agent has replied"
  (chat-test/fake-talks:reply! p "Polly")
  (chat:show! p)
  (test-user:settle)
  (check-equal? '("nothing to copy") (chat-test:reports-during (lambda () (chat-test:run! chat:copy-last-reply)))))

(define (status-of window)
  (find (lambda (el) (equal? (test-user:element-text el) (chat:show-status window)))
        (test-user:elements (test-user:screen) "status-line-segment")))

(test "a click on a chat's status segment selects its window and runs its source's entry of chat:status-menus there; a source with none only selects"
  (let* ([menus '()] [parrot-window (chat-test:view)]
         [echo-window (layout-split:split-view! parrot-window (layout-split:direction row))])
    (commands:define-command (echo-menu) "Notes the menu shown." (set! menus (cons (chat-test:current) menus)))
    (tables:set! chat:status-menus 'chat-test/fake-agents:echo echo-menu)
    (views:set-buffer! echo-window (chat:buffer e))
    (test-user:settle)
    (check (eq? parrot-window (chat-test:view)))
    (test-user:click-element! (status-of echo-window))
    (check-equal? (list e) menus)
    (check (eq? echo-window (chat-test:view)))
    (test-user:click-element! (status-of parrot-window))
    (check-equal? 1 (length menus))
    (check (eq? parrot-window (chat-test:view)))))

(test "chat:conversation? accepts a loaded source's conversation, and chat:chats-for gives every live one for no buffer"
  (check-equal? '(#t #t #f 2) (list (chat:conversation? e) (chat:conversation? p) (chat:conversation? 'x) (length (chat:chats-for #f)))))

(test "with no chat in the buffer's project, chat:toggle starts one of chat:default-source"
  (options:set! chat:default-source 'chat-test/fake-agents:parrot)
  (mkdir (string-append home "/other"))
  (call-with-output-file (string-append home "/other/notes.txt") (lambda (port) (put-string port "a\n")))
  (layout:switch-to-buffer (files:visit (string-append home "/other/notes.txt")))
  (test-user:press! "C-c a t")
  (let ([started (chat-test:current)])
    (check-equal? '(parrot #f) (list (chat-test/fake-talks:talk-kind started) (eq? started p)))
    (check-equal? (string-append home "/other/") (chat-test/fake-talks:talk-directory started)))
  (check-equal? '(3 1) (list (length (chat:chats-for (chat:buffer e))) (length (chat:chats-for (chat:buffer e) 'chat-test/fake-agents:echo))))
  (options:unset! chat:default-source))

(test "a chat's root is marked with its source and session, rewritten when the session changes, so a reload of chat finds every buffer, its prompt kept"
  (let ([echo-buffer (chat:buffer e)])
    (chat:show! e)
    (test-user:type! "draft")
    (chat-test/fake-talks:move! e "echo-moved")
    (test-user:settle)
    (let ([root (document:token (buffers:document echo-buffer) 0)])
      (check-equal? '(chat-test/fake-agents:echo "echo-moved")
        (list (document:node-attribute root 'source #f) (document:node-attribute root 'session #f))))
    (reload-modules! '((chat)))
    (test-user:settle)
    (check (eq? echo-buffer (chat:buffer e)))
    (check-equal? "Done now\ndraft\n" (chat-test:shown e))
    (check (eq? e (chat:conversation-of echo-buffer)))))
