(import (tuna) (test) (test-user) (test-runner) (pi) (chat) (pi-chat) (test-pi) (pi-chat-test))

(test "a session's whole history comes in at once, its Markdown made on chat's thread, every message drawn"
  (test-pi:save-session! "long-session"
    (apply append
      (map (lambda (n)
             (list (test-pi:entry (format "u~a" n) (and (> n 0) (format "a~a" (- n 1))) (test-pi:user-message (format "Ask ~a" n)))
                   (test-pi:entry (format "a~a" n) (format "u~a" n)
                     (test-pi:assistant-message "stop" (test-pi:text-block (format "Reply **~a**" n))))))
           (iota 50))))
  (let ([chat (pi:start (getenv "HOME") "long-session")])
    (test-runner:wait-until (lambda () (= 100 (length (pi:chat-transcript chat)))))
    (chat:show! chat)
    (test-runner:wait-until
      (lambda ()
        (let ([replies (pi-chat-test:elements "chat-reply")])
          (and (= 50 (length replies))
               (equal? '("49") (map test-user:element-text (test-user:elements (car (last-pair replies)) "markdown-strong")))))))
    (check-equal? 50 (length (pi-chat-test:elements "chat-user-message")))))
