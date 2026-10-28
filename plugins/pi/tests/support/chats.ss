;;; The pi plugin in fresh kernels with real helpers and the fake Pi
;;; (fake-pi.ss), for the plugin's integration tests: the plugins it needs,
;;; a private folder for helpers' sockets and the fake's sessions, the
;;; chat as text, and stopping every helper and fake Pi a test started, by
;;; its exact pid.
(import :std/source
        :tuna/kernel
        :tuna/lib/unix
        :tuna/lib/plugin-options
        :tuna/plugins/buffers/contract
        :tuna/plugins/commands/contract
        (only-in :tuna/plugins/files/contract default-directory)
        :tuna/plugins/pi/contract
        :tuna/plugins/commands/plugin :tuna/plugins/keys/plugin :tuna/plugins/settings/plugin
        :tuna/plugins/text-store/plugin :tuna/plugins/buffers/plugin :tuna/plugins/markdown/plugin
        :tuna/plugins/pi/plugin
        "../../../../tuna/tests/support/kernel"
        "../../../terminal/tests/support/memory-session")
(export pi-plugins
        fake-pi-path
        fake-pi-command
        with-chats
        on-editor
        start-chat-kernel
        open-chat-here!
        send!
        count-of
        the-chat
        chat-text
        chat-has?
        status-text
        wait-for
        helper-pids
        fake-pids
        kill-pid!
        pid-alive?
        find-node)

(def pi-plugins [commands keys settings rope-text-store memory-session buffers markdown pi])

(def fake-pi-path (path-expand "fake-pi.ss" (this-source-directory)))

;; The command that runs the fake Pi with its sessions in FOLDER, and MORE
;; arguments.
(def (fake-pi-command (folder : :string) . more) => :list
  (append ["gxi" fake-pi-path "--fake-sessions" folder] more))

(def (on-editor (thunk : :procedure)) => :t (call-on-editor-loop thunk))

;; Wait up to SECONDS for (READY?): whether it became true.
(def (wait-for (ready? : :procedure) (seconds : :real := 10)) => :boolean
  (let lp ((left seconds))
    (cond
     ((ready?) #t)
     ((<= left 0) #f)
     (else (thread-sleep! 0.02) (lp (- left 0.02))))))

(def folder-count 0)

(def (cmdline (pid : :string)) => (Maybe :string)
  (with-catch (lambda (e) #f)
              (lambda ()
                (let (text (call-with-input-file (string-append "/proc/" pid "/cmdline") (lambda (port) (read-line port #f))))
                  (and (string? text) (list->string (map (lambda (c) (if (char=? c #\nul) #\space c)) (string->list text))))))))

;; The pids of processes whose command line holds both WHAT and IN.
(def (pids-with (what : :string) (in : :string)) => :list
  (filter-map (lambda (name)
                (and (string->number name)
                     (let (cmd (cmdline name))
                       (and cmd (string-contains cmd what) (string-contains cmd in) (string->number name)))))
              (directory-files "/proc")))

(def test-folder-prefix "/tmp/tuna-pi-test-")

(def (helper-pids (folder : :string := test-folder-prefix)) => :list
  (filter pid-alive? (pids-with "tuna-pi-helper" folder)))

(def (fake-pids (folder : :string := test-folder-prefix)) => :list
  (filter pid-alive? (pids-with "fake-pi.ss" folder)))

(def (pid-alive? (pid : :fixnum)) => :boolean
  (and (fx> pid 0) (file-exists? (string-append "/proc/" (number->string pid)))
       (not (with-catch (lambda (e) #f)
                        (lambda ()
                          (let* ((stat (call-with-input-file (string-append "/proc/" (number->string pid) "/stat") read-line))
                                 (close (string-rindex stat #\))))
                            (and close (char=? (string-ref stat (+ close 2)) #\Z))))))))

(def (kill-pid! (pid : :fixnum)) => :void
  (when (pid-alive? pid)
    (with-catch void (lambda () (open-process-kill pid)))))

;; SIGKILL to PID, through kill(1): the tests need no signal binding.
(def (open-process-kill (pid : :fixnum)) => :void
  (let (p (open-process [path: "kill" arguments: ["-9" (number->string pid)]
                         stdin-redirection: #f stdout-redirection: #f stderr-redirection: #t]))
    (process-status p)
    (close-port p)))

;; Stop the helpers and fake Pis an earlier run left behind, when it was
;; killed before it could stop them: their folder names a pid that is gone.
(def (stop-orphans!) => :void
  (for-each (lambda (pid)
              (let* ((cmd (or (cmdline (number->string pid)) ""))
                     (at (string-contains cmd test-folder-prefix))
                     (rest (and at (substring cmd (+ at (string-length test-folder-prefix)) (string-length cmd))))
                     (dash (and rest (string-index rest #\-)))
                     (owner (and dash (string->number (substring rest 0 dash)))))
                (when (and owner (not (pid-alive? owner)))
                  (kill-pid! pid))))
            (append (helper-pids) (fake-pids))))

;; Run PROC with a new private folder for helpers' sockets and the fake's
;; sessions, the pi plugin's options pointing there (OPTIONS adds more),
;; then stop every helper and fake Pi started under it and remove it.
(def (with-chats (proc : :procedure) options: (options : :list := [])) => :t
  (stop-orphans!)
  (forget-memory-session!)
  (set! folder-count (+ folder-count 1))
  (let (folder (string-append test-folder-prefix (number->string (current-process-id)) "-" (number->string folder-count)))
    (make-private-directory folder)
    (try
     (set-plugin-options! pi (append options
                                     [(cons 'socket-directory folder) (cons 'leave-scope 'never)
                                      (cons 'pi-command (fake-pi-command folder))]))
     (proc folder)
     (finally
      (set-plugin-options! pi [])
      (for-each kill-pid! (append (helper-pids folder) (fake-pids folder)))
      (wait-for (lambda () (null? (append (helper-pids folder) (fake-pids folder)))) 5)
      (let remove ((path folder))
        (when (file-exists? path)
          (if (eq? (file-info-type (file-info path #f)) 'directory)
            (begin
              (for-each (lambda (name) (remove (path-expand name path))) (directory-files path))
              (with-catch void (lambda () (delete-directory path))))
            (with-catch void (lambda () (delete-file path))))))))))

(def (start-chat-kernel (thunk : :procedure) (more : :list := [])) => :t
  (call-with-fresh-kernel (append pi-plugins more) thunk))

;; Open the chat of FOLDER, as M-x pi in a buffer there does; with WAIT?,
;; wait until its Pi is up.
(def (open-chat-here! (folder : :string) wait?: (wait? : :boolean := #t)) => :void
  (on-editor (lambda ()
               (set-buffer-setting! (current-buffer) default-directory (string-append folder "/"))
               (call-command 'pi)))
  (when wait?
    (wait-for (lambda () (string-contains (status-text) "idle")))))

;; Type TEXT into the newest chat's prompt and send it with COMMAND, from
;; the chat's buffer.
(def (send! (text : :string) (command : :symbol := 'pi-send)) => :void
  (on-editor (lambda ()
               (let (chat (car (reverse (pi-chats))))
                 (switch-to-buffer (pi-chat-buffer chat))
                 (pi-add-to-prompt! chat text)
                 (call-command command)))))

;; How many times TEXT is in IN.
(def (count-of (text : :string) (in : :string)) => :fixnum
  (let lp ((from 0) (n 0))
    (let (at (string-contains in text from))
      (if at (lp (+ at (string-length text)) (+ n 1)) n))))

;; The newest chat.
(def (the-chat) => pi-chat
  (on-editor (lambda () (car (reverse (pi-chats))))))

;; The text of the newest chat's buffer, or "".
(def (chat-text) => :string
  (on-editor (lambda ()
               (let (chats (pi-chats))
                 (if (null? chats) "" (node-text-projection (buffer-root (pi-chat-buffer (car (reverse chats))))))))))

(def (chat-has? (text : :string) (seconds : :real := 10)) => :boolean
  (wait-for (lambda () (and (string-contains (chat-text) text) #t)) seconds))

;; The newest chat's status bar.
(def (status-text) => :string
  (on-editor (lambda ()
               (let (chats (pi-chats))
                 (if (null? chats)
                   ""
                   (let (status (find (lambda (n) (eq? (node-kind n) 'pi-status))
                                      (node-children (buffer-root (pi-chat-buffer (car (reverse chats)))))))
                     (if status (node-text-projection status) "")))))))

;; The first node under ROOT, depth first, for which (PRED node) holds.
(def (find-node (root : node) (pred : :procedure)) => (Maybe node)
  (let walk ((n root))
    (if (pred n) n (ormap walk (node-children n)))))
