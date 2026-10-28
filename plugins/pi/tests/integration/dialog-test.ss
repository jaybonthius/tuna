;;; A Pi extension's questions, with real helpers, the fake Pi, and the
;;; real minibuffer and completion: a question waits in the chat, which
;;; shows as blocked; RET on it asks in the minibuffer and sends the
;;; answer; C-g sends that it was cancelled. Every helper and fake Pi a
;;; test starts is stopped by its exact pid.
(import :std/test
        :tuna/kernel
        :tuna/plugins/buffers/contract
        :tuna/plugins/commands/contract
        :tuna/plugins/pi/contract
        :tuna/plugins/layout/plugin
        :tuna/plugins/minibuffer/plugin
        :tuna/plugins/completion/plugin
        "../../../keys/tests/support/keys"
        "../support/chats")
(export dialog-test)

;; Put point in the newest chat's question.
(def (focus-question!) => :void
  (on-editor (lambda ()
               (let* ((chat (car (reverse (pi-chats))))
                      (n (find-node (buffer-root (pi-chat-buffer chat))
                                    (lambda (n) (and (text-node? n)
                                                     (string-prefix? "Pi asks" (text-string (text-node-content n))))))))
                 (set-view-focus! (selected-view) n 1)))))

(def (question-shown?) => :boolean
  (chat-has? "Pi asks: Pick one\nAllow · Block"))

(def dialog-test
  (test-suite "tuna/plugins/pi: extension questions"
    (test-case "a question waits in the chat; RET answers it in the minibuffer; C-g cancels it"
      (with-chats
       (lambda (folder)
         (start-chat-kernel
          (lambda ()
            (start-editor-loop!)
            (open-chat-here! folder)
            (send! "dialog")
            (check (question-shown?) => #t)
            (check (and (string-contains (status-text) "blocked") #t) => #t)
            (check (wait-for (lambda () (eq? (pi-chat-state (the-chat)) 'blocked))) => #t)
            (focus-question!)
            (press "RET")
            (thread-sleep! 0.3)
            (press "RET")
            (check (chat-has? "Answer: Allow") => #t)
            (check (string-contains (chat-text) "Pi asks") => #f)
            (check (wait-for (lambda () (string-contains (status-text) "idle"))) => #t)
            ;; Cancelled.
            (send! "dialog")
            (check (question-shown?) => #t)
            (focus-question!)
            (press "RET")
            (thread-sleep! 0.3)
            (press "C-g")
            (check (chat-has? "Answer: cancelled") => #t)
            (check (wait-for (lambda () (eq? (pi-chat-state (the-chat)) 'done))) => #t))
          [layout minibuffer completion]))))))
