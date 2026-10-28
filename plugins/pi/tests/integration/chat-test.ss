;;; The pi plugin with real helpers and the fake Pi (../support/fake-pi.ss):
;;; a reply streaming with its thinking, tool blocks with partial output
;;; and folding, queued and steered prompts and stopping, the program
;;; status it reports, Pi stopping with its standard error and starting
;;; again, and a Pi too old. Every helper and fake Pi a test starts is
;;; stopped by its exact pid.
(import :std/test
        :tuna/kernel
        :tuna/plugins/buffers/contract
        :tuna/plugins/commands/contract
        (only-in :tuna/plugins/buttons/contract button-action)
        :std/interface
        :tuna/plugins/program-status/contract
        :tuna/plugins/pi/contract
        "../support/chats")
(export chat-test)

;; States the chat reported to the program-status service, newest first.
(def reported [])

(defclass recording-status () final: #t)
(implement ProgramStatus recording-status
  (report-program-status! (lambda (self b report)
                            (set! reported (cons [(program-status-report-state report) (program-status-report-kind report)]
                                                 reported)))))

(defplugin (status-recorder ctx)
  "Records what the chats report to the program-status service."
  provides: [program-status-service]
  (context-provide! ctx program-status-service (ProgramStatus (recording-status))))

;; States the contract's hook ran with, newest first.
(def states [])

(defplugin (state-recorder ctx)
  "Records what pi-chat-state-hook runs with."
  (context-add-hook! ctx pi-chat-state-hook 'test (lambda (chat state) (set! states (cons state states)))))

;; Focus the newest chat's text node whose text starts with PREFIX, at its
;; start, and run COMMAND there.
(def (at-node! (prefix : :string) (command : :symbol)) => :void
  (on-editor (lambda ()
               (let* ((chat (car (reverse (pi-chats))))
                      (n (find-node (buffer-root (pi-chat-buffer chat))
                                    (lambda (n) (and (text-node? n) (string-prefix? prefix (text-string (text-node-content n))))))))
                 (set-view-focus! (selected-view) n 1)
                 (call-command command)))))

(def chat-test
  (test-suite "tuna/plugins/pi: chats"
    (test-case "M-x pi opens a chat; a reply streams in after its thinking, which folds"
      (with-chats
       (lambda (folder)
         (set! reported [])
         (set! states [])
         (start-chat-kernel
          (lambda ()
            (start-editor-loop!)
            (open-chat-here! folder)
            (check (on-editor (lambda () (buffer-name (current-buffer))))
                   => (string-append "*pi: " (path-strip-directory folder) "*"))
            (check (string-contains (status-text) "fake/fake-model · low · idle") => 0)
            (send! "hello there")
            (check (chat-has? "You said: hello there") => #t)
            (check (chat-has? "▸ Thinking  (1 line)") => #t)
            (let (text (chat-text))
              (check (and (string-contains text "You\nhello there") #t) => #t)
              (check (count-of "hello there" text) => 2))
            (check (wait-for (lambda () (string-contains (status-text) "23% · $0.01"))) => #t)
            ;; TAB unfolds the thinking.
            (at-node! "▸ Thinking" 'pi-toggle)
            (check (chat-has? "▾ Thinking\nLet me think about it.") => #t)
            (check (wait-for (lambda () (eq? (pi-chat-state (the-chat)) 'done))) => #t)
            (check (reverse states) => '(working done))
            (check (car reported) => '(done #f))
            ;; A prompt an extension handles starts no run.
            (send! "/handled")
            (thread-sleep! 0.3)
            (check (and (string-contains (status-text) "idle") #t) => #t))
          [status-recorder state-recorder]))))

    (test-case "tool calls are blocks: key argument, duration, a preview of the output, an edit's diff"
      (with-chats
       (lambda (folder)
         (start-chat-kernel
          (lambda ()
            (start-editor-loop!)
            (open-chat-here! folder)
            (send! "tool")
            (check (chat-has? "Done.") => #t)
            (let (text (chat-text))
              (check (and (string-contains text "▸ read  notes.txt  0.1 s ✓\nfirst line\nsee ./notes.txt:3 here") #t) => #t)
              ;; A command's last five lines, its escape sequences gone.
              (check (and (string-contains text "▸ bash  printf 'one\\ntwo\\n'  0.1 s ✓\n… 2 earlier lines\n1\n2\n3\n4\n5") #t) => #t)
              (check (and (string-contains text "▸ edit  notes.txt  +1 −1  0.1 s ✓\n− old line\n+ new line") #t) => #t))
            ;; TAB shows all of a command's output.
            (at-node! "▸ bash" 'pi-toggle)
            (check (chat-has? "▾ bash  printf 'one\\ntwo\\n'  0.1 s ✓\none\ntwo\n1\n2") => #t)
            (at-node! "▾ bash" 'pi-toggle)
            (check (chat-has? "▸ bash") => #t))))))

    (test-case "prompts sent while Pi works queue in Pi; a steer too; C-c C-k stops Pi"
      (with-chats
       (lambda (folder)
         (start-chat-kernel
          (lambda ()
            (start-editor-loop!)
            (open-chat-here! folder)
            (send! "busy")
            (check (chat-has? "chunk-2 ") => #t)
            (check (and (string-contains (status-text) "replying") #t) => #t)
            (send! "afterwards")
            (check (wait-for (lambda () (string-contains (status-text) "1 queued"))) => #t)
            (send! "steering" 'pi-steer)
            (check (wait-for (lambda () (string-contains (status-text) "2 queued"))) => #t)
            (check (chat-has? "You said: steering") => #t)
            (check (chat-has? "You said: afterwards") => #t)
            (let (text (chat-text))
              ;; Each once, after the reply that was running; the steer first.
              (check (count-of "chunk-29" text) => 1)
              (check (< (string-contains text "chunk-29") (string-contains text "You said: steering")
                        (string-contains text "You said: afterwards"))
                     => #t))
            (check (wait-for (lambda () (string-contains (status-text) "idle"))) => #t)
            ;; Stopping: what is queued comes back to the prompt.
            (send! "busy")
            (check (wait-for (lambda () (= (count-of "chunk-2 " (chat-text)) 2))) => #t)
            (send! "queued then dropped")
            (check (wait-for (lambda () (string-contains (status-text) "1 queued"))) => #t)
            (on-editor (lambda () (call-command 'pi-abort)))
            (check (chat-has? "Stopped.") => #t)
            (check (wait-for (lambda () (string-contains (status-text) "idle"))) => #t)
            (check (chat-has? "queued then dropped" 2) => #t)
            (check (count-of "You said: queued then dropped" (chat-text)) => 0))))))

    (test-case "extension status texts show in the bar, without their escape sequences"
      (with-chats
       (lambda (folder)
         (start-chat-kernel
          (lambda ()
            (start-editor-loop!)
            (open-chat-here! folder)
            (send! "status")
            (check (chat-has? "Status set.") => #t)
            (check (wait-for (lambda () (string-contains (status-text) "· busy"))) => #t))))))

    (test-case "Pi stopping shows its standard error once, with a Restart button that starts it again"
      (with-chats
       (lambda (folder)
         (set! states [])
         (start-chat-kernel
          (lambda ()
            (start-editor-loop!)
            (open-chat-here! folder)
            (send! "hello first")
            (check (chat-has? "You said: hello first") => #t)
            (send! "die")
            (check (chat-has? "Pi stopped (exit status 3).") => #t)
            (check (chat-has? "fake pi: boom, the model went away") => #t)
            (check (count-of "Pi stopped" (chat-text)) => 1)
            (check (and (string-contains (status-text) "stopped") #t) => #t)
            (check (car states) => 'error)
            (check (wait-for (lambda () (null? (helper-pids folder)))) => #t)
            (on-editor (lambda ()
                         (let (b (find-node (buffer-root (pi-chat-buffer (car (pi-chats))))
                                            (lambda (n) (eq? (node-kind n) 'button))))
                           ((button-action b) b))))
            ;; A new helper on the session: the history is back.
            (check (wait-for (lambda () (string-contains (status-text) "idle"))) => #t)
            (check (chat-has? "You said: hello first") => #t)
            (check (count-of "Pi stopped" (chat-text)) => 0)
            (send! "hello again")
            (check (chat-has? "You said: hello again") => #t))
          [state-recorder]))))

    (test-case "a Pi older than 1.4.0 is refused with a clear error"
      (with-chats
       (lambda (folder)
         (start-chat-kernel
          (lambda ()
            (start-editor-loop!)
            (open-chat-here! folder wait?: #f)
            (check (chat-has? "Pi 1.3.0 is too old; Tuna's chat needs Pi 1.4.0 or newer") => #t)
            (check (and (string-contains (status-text) "stopped") #t) => #t))))
       options: [(cons 'pi-command ["gxi" fake-pi-path "--fake-version" "1.3.0"])]))))
