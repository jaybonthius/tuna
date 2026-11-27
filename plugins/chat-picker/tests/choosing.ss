(import (tuna) (test) (test-user) (test-runner) (buffers) (views) (layout) (files) (completion) (completion-list) (pi) (chat)
        (pi-chat) (chat-picker) (test-pi) (picking))

(define home (getenv "HOME"))

(define project (string-append home "/src/tuna"))

(system (string-append "mkdir -p " project "/lib && git init -q " project))

(call-with-output-file (string-append project "/lib/a.txt") (lambda (p) (put-string p "one\ntwo\nthree\n")))

(define file-buffer (files:visit (string-append project "/lib/a.txt")))

(layout:switch-to-buffer file-buffer)

(define chat (picking:started (string-append project "/")))

(define other (picking:started home))

(test "chat-picker:switch-to-chat reads a live chat, each by its buffer with its folder and activity, previewing each, the current last; C-g puts back what the view showed"
  (chat:show! chat)
  (test-user:press! "C-c a s")
  (picking:settled)
  (check-equal? (list (list (string-append "*pi: " (path-last home) "*") '(shadow . "~") '(shadow . "idle"))
                      (list "*pi: tuna*" '(shadow . "~/src/tuna/") '(shadow . "idle")))
                (picking:rows))
  (check (eq? (chat:buffer other) (views:buffer (car (layout:views)))))
  (check-equal? '(quit) (picking:press! "C-g"))
  (check (eq? (chat:buffer chat) (views:buffer (picking:view))))
  (test-user:press! "C-c a s")
  (picking:settled)
  (test-user:press! "RET")
  (check (eq? other (chat:conversation-of (views:buffer (picking:view))))))

(test "chat-picker:add-region-to adds the region to a chosen chat's prompt, the region's project's chats first, and shows the chat"
  (layout:switch-to-buffer file-buffer)
  (views:set-mark! (picking:view) #f)
  (check-equal? '("the region is empty") (picking:press! "C-c a o"))
  (views:set-point! (picking:view) 4)
  (views:set-mark! (picking:view) 13)
  (test-user:press! "C-c a o")
  (picking:settled)
  (check-equal? (list "*pi: tuna*" (string-append "*pi: " (path-last home) "*")) (picking:texts))
  (test-user:press! "RET")
  (check-equal? "*pi: tuna*" (buffers:name (views:buffer (picking:view))))
  (check-equal? "lib/a.txt:1-3" (picking:prompt-text chat))
  (chat:set-prompt! chat ""))

(test "called with what is no chat, the commands raise not a chat"
  (check-equal? "not a chat" (picking:violation (lambda () (chat-picker:switch-to-chat 'chat))))
  (check-equal? "not a chat" (picking:violation (lambda () (chat-picker:add-region-to 'chat)))))

(test "with no chat open there is nothing to choose"
  (for-each pi:stop! (pi:chats))
  (test-user:settle)
  (check-equal? '("no chat is open") (picking:press! "C-c a s")))
