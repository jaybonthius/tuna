;;; The terminal, program-status and notifications plugins together, with
;;; real helpers: a program's status (OSC 7501) shows in the terminal's
;;; status line and goes as the protocol says (a new prompt, input, a
;;; clear, a full reset); ConEmu progress stands for it until OSC 7501 is
;;; used; notifications (OSC 9, 777) and status changes out of sight reach
;;; the echo area. Every helper and program a test starts is stopped by
;;; its exact pid.
(import :std/test
        :tuna/kernel
        :tuna/plugins/buffers/contract
        :tuna/plugins/commands/contract
        (only-in :tuna/plugins/renderer/contract status-line-text)
        :tuna/plugins/program-status/plugin
        :tuna/plugins/notifications/plugin
        "../../tuna/tests/support/kernel"
        "../../tuna/tests/support/string-input"
        "../../plugins/keys/tests/support/keys"
        "../../plugins/terminal/tests/support/helpers"
        "../../plugins/terminal/tests/support/terminals")
(export terminal-status-test)

(def (status) => :string
  (on-editor (lambda () (status-line-text (selected-view) #f))))

(def (status-shows? (text : :string)) => :boolean
  (wait-for (lambda () (and (string-contains (status) text) #t)) 10))

(def (status-clear?) => :boolean
  (wait-for (lambda () (not (string-contains (status) "["))) 10))

(def (message-is? (text : :string)) => :boolean
  (wait-for (lambda () (equal? (current-message) text)) 10))

(def (run! (command : :string)) => :void
  (paste command)
  (press "RET"))

(def (with-status-shell (thunk : :procedure)) => :t
  (with-terminals
   (lambda (folder)
     (call-with-fresh-kernel
      (append [test-messages] terminal-plugins [test-terminal-settings program-status notifications])
      (lambda ()
        (start-editor-loop!)
        (on-editor (lambda () (call-command 'terminal)))
        (check (screen-has? "*terminal*" "$ ") => #t)
        (thunk))))))

(def terminal-status-test
  (test-suite "tests/integration: a terminal program's status and notifications"
    (test-case "OSC 7501 shows in the status line; a new prompt drops working, input drops done"
      (with-status-shell
       (lambda ()
         (run! "printf '\\033]7501;state=working:app=demo:progress=30\\007'")
         (check (status-shows? "[demo: 30%]") => #t)
         (run! "printf '\\033]7501;state=blocked:kind=question\\007'")
         ;; A report replaces its record whole, app and all.
         (check (status-shows? "[blocked: question]") => #t)
         (run! "printf '\\033]133;A\\007'")
         (check (status-clear?) => #t)
         (run! "printf '\\033]7501;state=done:app=demo\\007'")
         (check (status-shows? "[demo: done]") => #t)
         (press "RET")
         (check (status-clear?) => #t)
         ;; A record without an app has its nearest ancestor's.
         (run! "printf '\\033]7501;state=working:id=job:app=cargo\\007\\033]7501;state=blocked:id=job/step\\007'")
         (check (status-shows? "[cargo: blocked]") => #t))))

    (test-case "a clear, and a full reset, remove the records; then ConEmu progress shows again"
      (with-status-shell
       (lambda ()
         (run! "printf '\\033]9;4;1;40\\007'")
         (check (status-shows? "[40%]") => #t)
         (run! "printf '\\033]7501;state=error:id=job\\007'")
         (check (status-shows? "[error]") => #t)
         ;; Once a program uses OSC 7501, its ConEmu progress is not shown.
         (run! "printf '\\033]7501;state=clear\\007\\033]9;4;1;70\\007'")
         (check (status-clear?) => #t)
         (run! "printf '\\033c\\033]9;4;1;80\\007'")
         (check (status-shows? "[80%]") => #t))))

    (test-case "notifications reach the echo area, and status changes when the terminal is out of sight"
      (with-status-shell
       (lambda ()
         (run! "printf '\\033]9;hello\\007'")
         (check (message-is? "*terminal*: hello") => #t)
         (run! "printf '\\033]777;notify;Build;finished\\007'")
         (check (message-is? "Build: finished") => #t)
         ;; Looked at: no notification.
         (run! "printf '\\033]7501;state=blocked:app=demo:kind=permission\\007'")
         (check (status-shows? "[demo: blocked: permission]") => #t)
         (check (string-prefix? "demo" (current-message)) => #f)
         (run! "sleep 1; printf '\\033]7501;state=done:app=demo:msg=YWxsIGRvbmU=\\007'")
         (on-editor (lambda ()
                      (let (b (new-buffer "elsewhere" (new-text-node (new-text ""))))
                        (add-buffer! b)
                        (switch-to-buffer b))))
         (check (message-is? "demo: all done") => #t))))))
