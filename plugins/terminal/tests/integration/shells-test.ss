;;; Tuna's shell integration with the real shells, those installed: bash,
;;; zsh and fish start with it, with no startup files of the user's, and
;;; report their prompts, their commands' exit codes and their folders;
;;; bash and zsh set the title to the command. Every helper and program a
;;; test starts is stopped by its exact pid.
(import :std/test
        :std/misc/process
        :tuna/kernel
        :tuna/plugins/commands/contract
        :tuna/plugins/settings/contract
        :tuna/plugins/terminal/contract
        :tuna/plugins/terminal/plugin
        (only-in :tuna/plugins/terminal/io current-process-id)
        "../../../../tuna/tests/support/kernel"
        "../../../keys/tests/support/keys"
        "../support/helpers"
        "../support/terminals")
(export shells-test)

;; What the hooks ran with, newest first.
(def seen [])

(def (note! (entry : :list)) => :void
  (set! seen (cons entry seen)))

(def (seen? (entry : :list)) => :boolean
  (wait-for (lambda () (and (member entry seen) #t)) 15))

;; The shell the next kernel's terminal runs, and the home it gets.
(def shell-program [])
(def shell-home "")

(defplugin (integrated-shell ctx)
  "Runs terminals' programs as the shell under test, in an empty home, and records the hooks."
  requires: [settings-service]
  (context-set-setting! ctx terminal-shell shell-program)
  (context-set-setting! ctx terminal-environment
                        [(string-append "HOME=" shell-home)
                         (string-append "XDG_CONFIG_HOME=" shell-home "/config")
                         (string-append "XDG_DATA_HOME=" shell-home "/data")
                         "ENV" "ZDOTDIR" "PROMPT_COMMAND" "BASH_ENV"])
  (context-add-hook! ctx terminal-prompt-hook 'test (lambda (term kind) (note! ['prompt kind])))
  (context-add-hook! ctx terminal-command-finish-hook 'test (lambda (term code seconds) (note! ['finish code])))
  (context-add-hook! ctx terminal-title-hook 'test (lambda (term title) (note! ['title title])))
  (context-add-hook! ctx terminal-directory-hook 'test (lambda (term folder) (note! ['directory folder]))))

;; The path of the program NAME on PATH, or #f.
(def (on-path (name : :string)) => (Maybe :string)
  (let (path (getenv "PATH" ""))
    (find file-exists? (map (lambda ((folder : :string)) (path-expand name folder)) (string-split path #\:)))))

;; Run THUNK with a terminal running SHELL (a path) with the integration,
;; in an empty home removed afterwards.
(def (with-integrated-shell (shell : :string) (thunk : :procedure)) => :t
  (with-terminals
   (lambda (folder)
     (let (home (string-append "/tmp/tuna-shells-test-" (number->string (current-process-id))))
       (set! seen [])
       (set! shell-program [shell "-i"])
       (set! shell-home home)
       (run-process ["mkdir" "-p" (string-append home "/config") (string-append home "/data")])
       ;; Some startup file, or zsh asks a new user to make them.
       (run-process ["touch" (string-append home "/.zshrc")])
       (try
        (call-with-fresh-kernel
         (append terminal-plugins [integrated-shell])
         (lambda ()
           (start-editor-loop!)
           (on-editor (lambda () (call-command 'terminal)))
           (thunk home)))
        (finally (run-process ["rm" "-rf" home])))))))

(def (run! (command : :string)) => :void
  (paste command)
  (press "RET"))

(def (check-shell (name : :string) (title? : :boolean)) => :void
  (let (shell (on-path name))
    (when shell
      (with-integrated-shell shell
        (lambda (home)
          ;; The first prompt may come before Tuna's mirror connects,
          ;; which then sees only the screen.
          (check (screen-has? "*terminal*" (cond ((equal? name "fish") ">") ((equal? name "zsh") "%") (else "$"))) => #t)
          (run! "false")
          (check (seen? '(finish 1)) => #t)
          (check (seen? '(prompt primary)) => #t)
          (when title? (check (seen? '(title "false")) => #t))
          (run! "cd /tmp")
          (check (seen? '(finish 0)) => #t)
          (check (seen? '(directory "/tmp")) => #t))))))

(def shells-test
  (test-suite "tuna/plugins/terminal: shell integration"
    (test-case "bash reports its prompts, exit codes, folder and title"
      (check-shell "bash" #t))
    (test-case "zsh reports its prompts, exit codes, folder and title"
      (check-shell "zsh" #t))
    (test-case "fish reports its prompts, exit codes and folder"
      (check-shell "fish" #f))))
