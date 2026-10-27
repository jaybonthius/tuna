;;; Terminals coming back without their helpers, with real helpers: a
;;; simulated reboot (the helper asked to end, as a shutdown asks, and its
;;; shell gone, then Tuna started again from its session) brings back the
;;; saved screen under a note and a new shell in the terminal's folder; a
;;; helper killed while Tuna runs leaves a stale socket, which is removed,
;;; and the terminal comes back from what Tuna showed; with
;;; terminal-restore-start 'key the new shell waits for RET; killing a
;;; terminal on purpose removes its saved screen. Every helper and program a
;;; test starts is stopped by its exact pid.
(import :std/test
        :tuna/kernel
        :tuna/plugins/buffers/contract
        :tuna/plugins/commands/contract
        :tuna/plugins/settings/contract
        :tuna/plugins/session/contract
        :tuna/plugins/terminal/io
        :tuna/plugins/terminal/plugin
        "../../../keys/tests/support/keys"
        "../support/helpers"
        "../support/terminals")
(export revive-test)

(def restore-start 'auto)

(defplugin (saving-settings ctx)
  "Saves terminal screens every second; restored terminals start as restore-start says."
  requires: [settings-service]
  (context-set-setting! ctx terminal-save-interval 1)
  (context-set-setting! ctx terminal-restore-start restore-start))

(def (start (thunk : :procedure)) => :t
  (start-kernel thunk [saving-settings]))

;; The processes whose parent is PID.
(def (children (pid : :fixnum)) => :list
  (with-catch (lambda (e) [])
              (lambda ()
                (let (line (call-with-input-file (string-append "/proc/" (number->string pid) "/task/"
                                                               (number->string pid) "/children")
                             read-line))
                  (if (string? line) (filter-map string->number (string-split line #\space)) [])))))

;; End every test helper and its programs: each helper with SIGNAL, its
;; programs with SIGKILL, all by pid; wait until they are gone.
(def (end-helpers! (signal : :fixnum)) => :void
  (for-each (lambda (helper)
              (let (programs (children helper))
                (signal-group helper signal)
                (for-each kill-pid! programs)
                (wait-for (lambda () (not (or (pid-alive? helper) (ormap pid-alive? programs)))) 10)))
            (helper-pids)))

(def (saved-screen (folder : :string)) => (Maybe :string)
  (let (saved (path-expand "terminals" folder))
    (and (file-exists? saved)
         (let (names (filter (cut string-suffix? ".screen" <>) (directory-files saved)))
           (and (pair? names) (path-expand (car names) saved))))))

;; Whether the new shell's prompt shows after the note.
(def (new-prompt?) => :boolean
  (wait-for (lambda ()
              (let* ((text (screen-text "*terminal*"))
                     (note (string-contains text "Restored ")))
                (and note (string-contains (substring text note (string-length text)) "\n$ ") #t)))
            10))

(def (mode (path : :string)) => :fixnum
  (fxand (file-info-mode (file-info path)) #o777))

;; Start a terminal, go to FOLDER (as its shell would say with OSC 7) and
;; print a line, and wait until its helper saved the screen.
(def (terminal-in! (folder : :string) (line : :string)) => :void
  (on-editor (lambda () (call-command 'terminal)))
  (check (screen-has? "*terminal*" "$ ") => #t)
  (paste (string-append "cd " folder "; printf '\\033]7;file://localhost" folder "\\007'; echo " line))
  (press "RET")
  (check (screen-has? "*terminal*" (string-append "\n" line "\n")) => #t)
  ;; Saved within the second the test's settings give.
  (thread-sleep! 2.5)
  (check (and (saved-screen folder) #t) => #t))

(def revive-test
  (test-suite "tuna/plugins/terminal: terminals that come back without their helpers"
    (test-case "after a reboot a terminal shows its saved screen under a note, and a new shell in its folder"
      (with-terminals
       (lambda (folder)
         (set! restore-start 'auto)
         (start (lambda ()
                  (start-editor-loop!)
                  (terminal-in! folder "before-the-reboot")
                  (let (saved (saved-screen folder))
                    (check (mode saved) => #o600)
                    (check (mode (path-directory saved)) => #o700))
                  (on-editor save-session)))
         ;; The shutdown asks each helper to end, which saves its screen;
         ;; the reboot ends everything.
         (end-helpers! 15)
         (check (helper-pids) => [])
         (start (lambda ()
                  (restore-session)
                  (start-editor-loop!)
                  (on-editor (lambda () (switch-to-buffer (get-buffer "*terminal*"))))
                  (check (screen-has? "*terminal*" "before-the-reboot") => #t)
                  (check (screen-has? "*terminal*" "Restored ") => #t)
                  ;; A new shell, in the folder, with a new helper.
                  (check (wait-for (lambda () (= (length (helper-pids)) 1)) 10) => #t)
                  (check (new-prompt?) => #t)
                  (paste "pwd")
                  (press "RET")
                  (check (screen-has? "*terminal*" (string-append "\n" folder "\n")) => #t)
                  ;; Nothing ran again: the line was printed once.
                  (let (text (screen-text "*terminal*"))
                    (check (length (filter (cut equal? "before-the-reboot" <>) (string-split text #\newline))) => 1)))))))

    (test-case "a helper killed while Tuna runs leaves a stale socket, removed as the terminal comes back"
      (with-terminals
       (lambda (folder)
         (set! restore-start 'auto)
         (start (lambda ()
                  (start-editor-loop!)
                  (terminal-in! folder "before-the-kill")
                  (let (sockets (lambda () (filter (cut string-suffix? ".sock" <>) (directory-files folder))))
                    (check (length (sockets)) => 1)
                    (end-helpers! 9)
                    ;; Its socket is stale until the new helper listens there.
                    (check (screen-has? "*terminal*" "Restored ") => #t)
                    (check (wait-for (lambda () (= (length (helper-pids)) 1)) 10) => #t)
                    (check (wait-for (lambda () (= (length (sockets)) 1)) 10) => #t)
                    (check (new-prompt?) => #t)
                    (paste "echo after-the-kill")
                    (press "RET")
                    (check (screen-has? "*terminal*" "\nafter-the-kill\n") => #t)
                    (check (and (string-contains (screen-text "*terminal*") "before-the-kill") #t) => #t)))))))

    (test-case "with terminal-restore-start 'key, the new shell waits for RET"
      (with-terminals
       (lambda (folder)
         (set! restore-start 'key)
         (start (lambda ()
                  (start-editor-loop!)
                  (terminal-in! folder "before-the-reboot")
                  (on-editor save-session)))
         (end-helpers! 15)
         (start (lambda ()
                  (restore-session)
                  (start-editor-loop!)
                  (on-editor (lambda () (switch-to-buffer (get-buffer "*terminal*"))))
                  (check (screen-has? "*terminal*" "Press RET to start it.") => #t)
                  (type! "x")
                  (thread-sleep! 0.5)
                  (check (helper-pids) => [])
                  (press "RET")
                  (check (wait-for (lambda () (= (length (helper-pids)) 1)) 10) => #t)
                  (check (new-prompt?) => #t)
                  (paste "echo started")
                  (press "RET")
                  (check (screen-has? "*terminal*" "\nstarted\n") => #t))))))

    (test-case "killing a terminal on purpose removes its saved screen"
      (with-terminals
       (lambda (folder)
         (set! restore-start 'auto)
         (start (lambda ()
                  (start-editor-loop!)
                  (terminal-in! folder "to-be-killed")
                  (let (helpers (helper-pids))
                    (on-editor (lambda () (kill-buffer (get-buffer "*terminal*"))))
                    (check (wait-for (lambda () (not (ormap pid-alive? helpers))) 10) => #t)
                    (check (saved-screen folder) => #f)))))))))
