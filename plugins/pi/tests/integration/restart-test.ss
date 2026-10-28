;;; Chats that outlive Tuna, with real helpers and the fake Pi: Tuna
;;; restarting mid-reply reconnects and the helper's replay gives the same
;;; transcript as Pi's history; a helper gone (a reboot) or ended idle
;;; comes back on Pi's session file; killing the chat's buffer ends its
;;; helper; a reload swaps in a new helper. Every helper and fake Pi a
;;; test starts is stopped by its exact pid.
(import :std/test
        :tuna/kernel
        :tuna/plugins/buffers/contract
        :tuna/plugins/commands/contract
        :tuna/plugins/session/contract
        :tuna/plugins/pi/contract
        "../support/chats")
(export restart-test)

(def (idle?) => :boolean
  (wait-for (lambda () (string-contains (status-text) "idle")) 15))

;; Start a kernel that restores the saved session and runs THUNK.
(def (restored (thunk : :procedure)) => :t
  (start-chat-kernel (lambda ()
                       (restore-session)
                       (start-editor-loop!)
                       (thunk))))

(def restart-test
  (test-suite "tuna/plugins/pi: chats that outlive Tuna"
    (test-case "Tuna restarting mid-reply reconnects; the reply streams on, as Pi's history has it"
      (with-chats
       (lambda (folder)
         (start-chat-kernel
          (lambda ()
            (start-editor-loop!)
            (open-chat-here! folder)
            (send! "slow")
            (check (chat-has? "chunk-5 ") => #t)
            (on-editor save-session)))
         ;; Tuna is gone; the helper and Pi go on.
         (check (length (helper-pids folder)) => 1)
         (let (streamed
               (restored
                (lambda ()
                  (check (chat-has? "chunk-") => #t)
                  ;; Still streaming when it came back.
                  (check (< (count-of "chunk-" (chat-text)) 40) => #t)
                  (check (chat-has? "chunk-39" 15) => #t)
                  (check (idle?) => #t)
                  (on-editor save-session)
                  (chat-text))))
           (check (count-of "chunk-0 " streamed) => 1)
           (check (count-of "You\nslow" streamed) => 1)
           ;; Another restart draws the chat from Pi's history alone: the same.
           (restored
            (lambda ()
              (check (idle?) => #t)
              (check (chat-text) => streamed)))))))

    (test-case "after a reboot, with no helper, the chat comes back on Pi's session file"
      (with-chats
       (lambda (folder)
         (start-chat-kernel
          (lambda ()
            (start-editor-loop!)
            (open-chat-here! folder)
            (send! "hello before")
            (check (chat-has? "You said: hello before") => #t)
            (on-editor save-session)))
         (let (old (helper-pids folder))
           (check (length old) => 1)
           ;; The reboot: everything ends, the socket stays behind.
           (for-each kill-pid! (append old (fake-pids folder)))
           (check (wait-for (lambda () (null? (append (helper-pids folder) (fake-pids folder))))) => #t)
           (restored
            (lambda ()
              (check (chat-has? "You said: hello before") => #t)
              (check (idle?) => #t)
              (let (new (helper-pids folder))
                (check (length new) => 1)
                (check (equal? new old) => #f))
              (send! "hello after")
              (check (chat-has? "You said: hello after") => #t)))))))

    (test-case "a helper with no Tuna and Pi idle ends itself; the chat comes back from the session"
      (with-chats
       (lambda (folder)
         (start-chat-kernel
          (lambda ()
            (start-editor-loop!)
            (open-chat-here! folder)
            (send! "hello idle")
            (check (chat-has? "You said: hello idle") => #t)
            (check (idle?) => #t)
            (on-editor save-session)))
         (check (wait-for (lambda () (null? (append (helper-pids folder) (fake-pids folder)))) 8) => #t)
         (check (filter (cut string-suffix? ".sock" <>) (directory-files folder)) => [])
         (restored
          (lambda ()
            (check (chat-has? "You said: hello idle") => #t)
            (check (length (helper-pids folder)) => 1))))
       options: [(cons 'idle-exit 1)]))

    (test-case "killing a chat's buffer ends its helper and Pi; a reload swaps in a new helper"
      (with-chats
       (lambda (folder)
         (start-chat-kernel
          (lambda ()
            (start-editor-loop!)
            (open-chat-here! folder)
            (send! "hello reload")
            (check (chat-has? "You said: hello reload") => #t)
            (let (old (helper-pids folder))
              (on-editor (lambda () (call-command 'pi-reload)))
              (check (wait-for (lambda () (let (now (helper-pids folder))
                                            (and (= (length now) 1) (not (equal? now old))))))
                     => #t)
              (check (idle?) => #t)
              (check (count-of "You said: hello reload" (chat-text)) => 1))
            (on-editor (lambda () (kill-buffer (pi-chat-buffer (car (pi-chats))))))
            (check (wait-for (lambda () (null? (append (helper-pids folder) (fake-pids folder))))) => #t)
            (check (on-editor pi-chats) => []))))))))
