(import (test-user) (chat) (pi-chat) (test-pi) (pi-chat-test))

(chat:show! (pi-chat-test:started (getenv "HOME") "kept-session"))
(test-user:type! "unsent words")
