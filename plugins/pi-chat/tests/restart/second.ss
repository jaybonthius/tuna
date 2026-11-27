(import (test) (test-runner) (pi) (chat) (pi-chat) (test-pi) (pi-chat-test))

(test "the chat on the saved session shows the unsent prompt"
  (test-runner:wait-until (lambda () (pair? (pi:chats))))
  (let ([chat (car (pi:chats))])
    (pi-chat-test:idle chat)
    (check-equal? "kept-session" (pi:chat-session-id chat))
    (check-equal? "unsent words" (pi-chat-test:prompt-text chat))))
