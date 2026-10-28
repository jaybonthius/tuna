;;; Moving through a chat, with real helpers, the fake Pi and the real
;;; files plugin: RET on FILE:LINE in a tool's output opens the file at
;;; that line, and on a tool's header the tool's file (an edit at the line
;;; it changed); n and p move between your messages; M-p and M-n bring
;;; back earlier prompts; the transcript cannot be edited. Every helper and
;;; fake Pi a test starts is stopped by its exact pid.
(import :std/test
        :tuna/kernel
        :tuna/plugins/buffers/contract
        :tuna/plugins/commands/contract
        :tuna/plugins/pi/contract
        :tuna/plugins/layout/plugin
        :tuna/plugins/minibuffer/plugin
        :tuna/plugins/completion/plugin
        :tuna/plugins/files/plugin
        "../../../terminal/tests/support/memory-session"
        "../support/chats")
(export editor-test)

(def editor-plugins [layout minibuffer completion files])

;; Focus the newest chat's text node holding TEXT, at the character
;; OFFSET after where TEXT starts in it, and run COMMAND (#f for none).
(def (at-text! (text : :string) (offset : :fixnum) (command :? :symbol)) => :void
  (on-editor (lambda ()
               (let* ((chat (car (reverse (pi-chats))))
                      (n (find-node (buffer-root (pi-chat-buffer chat))
                                    (lambda (n) (and (text-node? n) (string-contains (text-string (text-node-content n)) text))))))
                 (switch-to-buffer (pi-chat-buffer chat))
                 (set-view-focus! (selected-view) n
                                  (+ 1 offset (string-contains (text-string (text-node-content n)) text)))
                 (when command (call-command command))))))

;; The current buffer's name, and point's line in it.
(def (where) => :list
  (on-editor (lambda () [(buffer-name (current-buffer)) (text-line-at (current-text) (point))])))

(def (focused-text) => :string
  (on-editor (lambda () (text-string (current-text)))))

(def (prompt-text) => :string
  (on-editor (lambda ()
               (let (chat (car (reverse (pi-chats))))
                 (text-string (text-node-content
                               (find-node (buffer-root (pi-chat-buffer chat))
                                          (lambda (n) (and (text-node? n) (eq? (node-kind (node-parent n)) 'pi-prompt))))))))))

(def editor-test
  (test-suite "tuna/plugins/pi: moving through a chat"
    (test-case "RET opens the file at point: FILE:LINE in output, a tool's file, an edit at its line"
      (with-chats
       (lambda (folder)
         (set-memory-session-state-directory! folder)
         (call-with-output-file (path-expand "notes.txt" folder)
           (lambda (port) (write-string "one\nold line\nthree\n" port)))
         (start-chat-kernel
          (lambda ()
            (start-editor-loop!)
            (open-chat-here! folder)
            (send! "tool")
            (check (chat-has? "Done.") => #t)
            (at-text! "▸ read" 2 'pi-open-at-point)
            (check (where) => ["notes.txt" 1])
            (at-text! "▸ edit" 2 'pi-open-at-point)
            (check (where) => ["notes.txt" 2])
            (at-text! "./notes.txt:3" 3 'pi-open-at-point)
            (check (where) => ["notes.txt" 3]))
          editor-plugins)
         (set-memory-session-state-directory! #f))))

    (test-case "n and p move between your messages; M-p and M-n bring back prompts; the transcript is read-only"
      (with-chats
       (lambda (folder)
         (set-memory-session-state-directory! folder)
         (start-chat-kernel
          (lambda ()
            (start-editor-loop!)
            (open-chat-here! folder)
            (send! "hello one")
            (check (chat-has? "You said: hello one") => #t)
            (send! "hello two")
            (check (chat-has? "You said: hello two") => #t)
            ;; From the prompt, p goes back to your last message.
            (on-editor (lambda ()
                         (let* ((chat (car (reverse (pi-chats))))
                                (prompt (find-node (buffer-root (pi-chat-buffer chat))
                                                   (lambda (n) (and (text-node? n) (eq? (node-kind (node-parent n)) 'pi-prompt))))))
                           (set-view-focus! (selected-view) prompt 1))))
            (on-editor (lambda () (call-command 'pi-previous-message)))
            (check (focused-text) => "hello two")
            (on-editor (lambda () (call-command 'pi-previous-message)))
            (check (focused-text) => "hello one")
            (on-editor (lambda () (call-command 'pi-next-message)))
            (check (focused-text) => "hello two")
            (check (on-editor (lambda () (with-catch (lambda (e) 'refused) (lambda () (insert "x") 'inserted)))) => 'refused)
            ;; M-p and M-n in the prompt.
            (on-editor (lambda () (call-command 'pi-previous-prompt)))
            (check (prompt-text) => "hello two")
            (on-editor (lambda () (call-command 'pi-previous-prompt)))
            (check (prompt-text) => "hello one")
            (on-editor (lambda () (call-command 'pi-next-prompt)))
            (check (prompt-text) => "hello two")
            (on-editor (lambda () (call-command 'pi-next-prompt)))
            (check (prompt-text) => ""))
          editor-plugins)
         (set-memory-session-state-directory! #f))))))
