;;; The terminal plugin in fresh kernels with real helpers, for the
;;; plugin's integration tests: the plugins it needs, sh as the program,
;;; the screen as text, and stopping every helper a test started, by its
;;; exact pid.
(import :std/test
        :tuna/kernel
        :tuna/lib/plugin-options
        :tuna/plugins/buffers/contract
        :tuna/plugins/settings/contract
        :tuna/plugins/commands/plugin :tuna/plugins/keys/plugin :tuna/plugins/settings/plugin
        :tuna/plugins/text-store/plugin :tuna/plugins/buffers/plugin
        :tuna/plugins/terminal/plugin
        "../../../../tuna/tests/support/kernel"
        "memory-session"
        "helpers")
(export terminal-plugins
        test-terminal-settings
        on-editor
        named-terminal
        screen-text
        screen-has?
        helper-pids
        with-terminals
        start-kernel)

(def terminal-plugins [commands keys settings rope-text-store memory-session buffers terminals])

;; Settings for the tests' terminals: sh, no rc files, a known prompt.
(defplugin (test-terminal-settings ctx)
  "Runs terminals' programs as plain sh."
  requires: [settings-service]
  (context-set-setting! ctx terminal-shell ["/bin/sh"])
  (context-set-setting! ctx terminal-environment ["PS1=$ " "ENV" "HOME=/tmp"]))

(def (on-editor (thunk : :procedure)) => :t (call-on-editor-loop thunk))

;; The terminal of the buffer named NAME, or #f.
(def (named-terminal (name : :string))
  (on-editor (lambda ()
               (let (b (get-buffer name))
                 (and b (let (n (buffer-root b))
                          (and (eq? (node-kind n) 'terminal) b)))))))

;; The text of buffer B's rows, one line each.
(def (screen-text (name : :string)) => :string
  (on-editor (lambda ()
               (let (b (get-buffer name))
                 (if b (node-text-projection (buffer-root b)) "")))))

(def (screen-has? (name : :string) (text : :string)) => :boolean
  (wait-for (lambda () (and (string-contains (screen-text name) text) #t)) 10))

(def (helper-pids) => :list
  (filter-map (lambda (name)
                (let (path (path-expand name "/proc"))
                  (and (string->number name)
                       (with-catch (lambda (e) #f)
                                   (lambda ()
                                     (let (cmd (call-with-input-file (path-expand "cmdline" path) read-line))
                                       (and (string? cmd) (string-contains cmd "tuna-terminal-helper")
                                            (string-contains cmd "/tmp/tuna-terminal-test-")
                                            (string->number name))))))))
              (directory-files "/proc")))

;; Run PROC with the plugins on, terminals' sockets in a test folder, and
;; afterwards stop every helper started under it, and its program.
(def (with-terminals (proc : :procedure)) => :t
  (forget-memory-session!)
  (call-with-test-folder
   (lambda (folder)
     (set-plugin-options! terminals [(cons 'socket-directory folder) (cons 'leave-scope 'never)])
     (try
      (proc folder)
      (finally
       (set-plugin-options! terminals [])
       (for-each (lambda (pid) (kill-pid! pid)) (helper-pids)))))))

(def (start-kernel (thunk : :procedure) (more : :list := [])) => :t
  (call-with-fresh-kernel (append terminal-plugins [test-terminal-settings] more) thunk))

