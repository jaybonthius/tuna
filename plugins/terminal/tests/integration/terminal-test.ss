;;; The terminal plugin with real helpers: a shell in a buffer, its keys,
;;; what it reports, its exit, and a restart of the Tuna side that gets the
;;; same screen back from the helper. Every helper and program a test
;;; starts is stopped by its exact pid.
(import :std/test
        :tuna/kernel
        :tuna/lib/plugin-options
        :tuna/plugins/buffers/contract
        :tuna/plugins/commands/contract
        :tuna/plugins/settings/contract
        (only-in :tuna/plugins/files/contract default-directory)
        :tuna/plugins/session/contract
        :tuna/plugins/terminal/contract
        :tuna/plugins/commands/plugin :tuna/plugins/keys/plugin :tuna/plugins/settings/plugin
        :tuna/plugins/text-store/plugin :tuna/plugins/buffers/plugin
        :tuna/plugins/terminal/plugin
        "../../../../tuna/tests/support/kernel"
        "../../../keys/tests/support/keys"
        "../support/memory-session"
        "../support/helpers")
(export terminal-test)

(def terminal-plugins [commands keys settings rope-text-store memory-session buffers terminals])

;; Settings for the tests' terminals: sh, no rc files, a known prompt.
(defplugin (test-terminal-settings ctx)
  "Runs terminals' programs as plain sh."
  requires: [settings-service]
  (context-set-setting! ctx terminal-shell ["/bin/sh"])
  (context-set-setting! ctx terminal-environment ["PS1=$ " "ENV" "HOME=/tmp"]))

;; What the terminal hooks reported, newest first.
(def seen [])

(defplugin (terminal-hook-recorder ctx)
  "Records what the terminal hooks run with."
  (context-add-hook! ctx terminal-title-hook 'test (lambda (term title) (set! seen (cons ['title title] seen))))
  (context-add-hook! ctx terminal-directory-hook 'test
                     (lambda (term directory) (set! seen (cons ['directory directory] seen))))
  (context-add-hook! ctx terminal-bell-hook 'test (lambda (term) (set! seen (cons ['bell] seen)))))

(defplugin (title-naming ctx)
  "Names terminal buffers after their titles."
  requires: [settings-service]
  (context-set-setting! ctx terminal-buffer-name-function 'title))

(def (on-editor (thunk : :procedure)) => :t (call-on-editor-loop thunk))

;; Every terminal's pids seen, to stop them however the test ends.
(def pids [])

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

(def terminal-test
  (test-suite "tuna/plugins/terminal: terminals"
    (test-case "M-x terminal runs a shell in a buffer; keys reach it, its output fills the rows"
      (with-terminals
       (lambda (folder)
         (start-kernel
          (lambda ()
            (start-editor-loop!)
            (on-editor (lambda () (call-command 'terminal)))
            (check (and (named-terminal "*terminal*") #t) => #t)
            (check (screen-has? "*terminal*" "$ ") => #t)
            (type! "e" "c" "h" "o" "SPC" "h" "i" "RET")
            (check (screen-has? "*terminal*" "\nhi\n") => #t)
            (paste "printf 'two\\nlines\\n'")
            (press "RET")
            (check (screen-has? "*terminal*" "two\nlines") => #t))))))

    (test-case "titles, folders and the bell run the contract's hooks; the title can rename the buffer"
      (with-terminals
       (lambda (folder)
         (set! seen [])
         (start-kernel
          (lambda ()
            (start-editor-loop!)
            (on-editor (lambda () (call-command 'terminal)))
            (check (screen-has? "*terminal*" "$ ") => #t)
            (paste "printf '\\033]2;work\\007\\033]7;file://localhost/tmp\\007\\a'")
            (press "RET")
            (check (wait-for (lambda () (named-terminal "*terminal: work*")) 10) ? values)
            (check (wait-for (lambda () (member '(bell) seen)) 5) ? values)
            (check (and (member '(title "work") seen) #t) => #t)
            (check (and (member '(directory "/tmp") seen) #t) => #t)
            (check (on-editor (lambda () (buffer-local-value default-directory (get-buffer "*terminal: work*"))))
                   => "/tmp/"))
          [terminal-hook-recorder title-naming]))))

    (test-case "when its program ends, the buffer goes and so does the helper"
      (with-terminals
       (lambda (folder)
         (start-kernel
          (lambda ()
            (start-editor-loop!)
            (on-editor (lambda () (call-command 'terminal)))
            (check (screen-has? "*terminal*" "$ ") => #t)
            (let (helpers (helper-pids))
              (check (length helpers) => 1)
              (paste "exit")
              (press "RET")
              (check (wait-for (lambda () (not (named-terminal "*terminal*"))) 10) => #t)
              (check (wait-for (lambda () (not (pid-alive? (car helpers)))) 10) => #t)))))))

    (test-case "a restarted Tuna gets the same screen back from the helper, and output goes on"
      (with-terminals
       (lambda (folder)
         (let (before #f)
           (start-kernel
            (lambda ()
              (start-editor-loop!)
              (on-editor (lambda () (call-command 'terminal)))
              (check (screen-has? "*terminal*" "$ ") => #t)
              (paste "for i in 1 2 3; do echo line$i; done; printf '\\033[1;32mgreen\\033[0m\\n'")
              (press "RET")
              (check (screen-has? "*terminal*" "green") => #t)
              (set! before (screen-text "*terminal*"))
              (on-editor save-session)))
           ;; That Tuna is gone; its helper is not.
           (check (length (helper-pids)) => 1)
           (start-kernel
            (lambda ()
              (restore-session)
              (start-editor-loop!)
              (on-editor void)
              (check (screen-has? "*terminal*" "green") => #t)
              (check (screen-text "*terminal*") => before)
              ;; A layout would show it again in its view.
              (on-editor (lambda () (switch-to-buffer (get-buffer "*terminal*"))))
              (paste "echo after")
              (press "RET")
              (check (screen-has? "*terminal*" "\nafter\n") => #t)))))))

    (test-case "the alternate screen shows the screen's rows only, and the scrollback comes back after it"
      (with-terminals
       (lambda (folder)
         (start-kernel
          (lambda ()
            (start-editor-loop!)
            (on-editor (lambda () (call-command 'terminal)))
            (check (screen-has? "*terminal*" "$ ") => #t)
            (paste "seq 1 100; printf '\\033[?1049hFULL'; sleep 2; printf '\\033[?1049l'")
            (press "RET")
            (check (screen-has? "*terminal*" "FULL") => #t)
            (check (on-editor (lambda () (node-attribute (buffer-root (get-buffer "*terminal*")) 'screen)))
                   => 'alternate)
            (check (on-editor (lambda () (node-item-count (buffer-root (get-buffer "*terminal*"))))) => 24)
            (check (screen-has? "*terminal*" "\n100\n") => #t)
            (check (on-editor (lambda () (node-attribute (buffer-root (get-buffer "*terminal*")) 'screen)))
                   => 'primary))))))))
