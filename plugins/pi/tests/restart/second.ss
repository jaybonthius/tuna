(import (test) (test-runner) (options) (processes) (pi) (test-pi) (pi-test))

;; pi starts the chats it saved in a task, which runs after this form.
(options:set! pi:command '("pi" "--from-init"))

(test "the saved chat is started again on its session, with the configured command"
  (test-runner:wait-until (lambda () (pair? (pi:chats))))
  (let ([chat (car (pi:chats))])
    (pi-test:idle chat)
    (check-equal? '(1 "kept-session") (list (length (pi:chats)) (pi:chat-session-id chat)))
    (check-equal? '("--from-init" "--mode" "rpc" "--session-id" "kept-session") (test-pi:arguments (pi-test:fake chat)))))
