(import (tuna) (test) (test-runner) (test-user) (hooks) (tables) (options) (buffers) (views) (layout) (modes) (commands)
        (files) (processes) (runs) (command-picker) (shell-commands) (shell-commands-test))

(define run shell-commands-test:run)

(define ended shell-commands-test:ended)

(define output shell-commands-test:output)

(define saved 0)

(define (count-save next) (set! saved (+ saved 1)))

(advice-add! shell-commands:save-buffers count-save)

(define (compilation) (buffers:find "*compilation*"))

(shell-commands-test:folder! "proj")
(shell-commands-test:folder! "other")
(shell-commands-test:write-file! "proj/foo.py" "print('foo')\n")
(shell-commands-test:write-file! "other/bar.py" "print('bar')\n")

(define foo (files:visit "~/proj/foo.py"))
(define bar (files:visit "~/other/bar.py"))

(buffers:with-buffer foo (options:set-local! shell-commands:compile-command "echo foo"))
(buffers:with-buffer bar (options:set-local! shell-commands:compile-command "echo bar"))

(test "compile reads a line from the current buffer's compile command, saves buffers, and runs it in *compilation*, in compilation-mode, which runs:started entries see"
  (let* ([entered '()] [note (lambda (b) (set! entered (cons (modes:major-mode b) entered)))])
    (hooks:add! runs:started note)
    (layout:switch-to-buffer foo)
    (test-user:press! "M-x")
    (test-user:type! "shell-commands:compile")
    (test-user:press! "RET")
    (check-equal? "echo foo" (shell-commands-test:input))
    (test-user:press! "RET")
    (check-equal? 0 (ended (compilation)))
    (check-equal? '(shell-commands:compilation-mode (shell-commands:compilation-mode) "foo" "~/proj/" 1)
                  (list (modes:major-mode (compilation)) entered (output (compilation)) (shell-commands-test:header-folder (compilation)) saved))
    (check-equal? "echo foo" (car (shell-commands:compile-history)))
    (hooks:remove! runs:started note)))

(test "g in compile's buffer runs the build again through recompile, which saves buffers, also after a reload of runs"
  (let ([build (compilation)])
    (layout:switch-to-buffer build)
    (test-user:press! "g")
    (ended build)
    (reload-modules! '((runs)))
    (test-user:press! "g")
    (ended build)
    (check-equal? '(3 shell-commands:compilation-mode "foo") (list saved (modes:major-mode build) (output build)))))

(test "C-u g edits the line first, a list command offered quoted"
  (let ([listed (runs:start-for-user "*listed*" '("echo" "it's") (processes:options [directory "~/"]) shell-commands:compilation-mode)])
    (ended listed)
    (layout:switch-to-buffer listed)
    (test-user:press! "C-u g")
    (check-equal? "echo 'it'\\''s'" (shell-commands-test:input))
    (test-user:press! "C-a C-k")
    (test-user:type! "echo edited")
    (test-user:press! "RET")
    (ended listed)
    (check-equal? "edited" (output listed))))

(test "recompile outside compile's buffers runs the current buffer's compile command in *compilation*, in the folder of the run there"
  (layout:switch-to-buffer bar)
  (run shell-commands:recompile #f)
  (ended (compilation))
  (check-equal? '("bar" "~/proj/" shell-commands:compilation-mode)
                (list (output (compilation)) (shell-commands-test:header-folder (compilation)) (modes:major-mode (compilation)))))

(test "C-u starts recompile's read from that line"
  (layout:switch-to-buffer bar)
  (test-user:press! "C-u M-x")
  (test-user:type! "shell-commands:recompile")
  (test-user:press! "RET")
  (check-equal? "echo bar" (shell-commands-test:input))
  (check (for-all cancelled? (shell-commands-test:reports-during (lambda () (test-user:press! "C-g"))))))

(test "with no run in the build's buffer, the folder is the current buffer's"
  (buffers:kill! (compilation))
  (layout:switch-to-buffer bar)
  (run shell-commands:recompile #f)
  (ended (compilation))
  (check-equal? '("bar" "~/other/") (list (output (compilation)) (shell-commands-test:header-folder (compilation)))))

(test "in M-&'s buffer recompile runs the compile command in compile's buffer and leaves M-&'s run, mode and g as they were"
  (options:set! shell-commands:compile-command "echo built")
  (run shell-commands:async-shell-command "echo async")
  (let ([async (buffers:find "*Async Shell Command*")])
    (ended async)
    (layout:switch-to-buffer async)
    (run shell-commands:recompile #f)
    (ended (compilation))
    (check-equal? '("built" "async" runs:mode #t)
                  (list (output (compilation)) (output async) (modes:major-mode async)
                        (eq? (buffers:with-buffer async (buffers:revert-function)) runs:run-again)))))

(test "a renamed build buffer reruns its own run in its own folder"
  (let ([build (compilation)])
    (buffers:rename! build "*old build*")
    (layout:switch-to-buffer build)
    (test-user:press! "g")
    (ended build)
    (check-equal? '("*old build*" "built" "~/other/" #f)
                  (list (buffers:name build) (output build) (shell-commands-test:header-folder build) (compilation)))))

(tables:define-table mine-keymap)
(hooks:define-hook mine-hook)
(modes:define-major-mode mine (parent shell-commands:compilation-mode) (keymap mine-keymap) (hook mine-hook))

(test "in a mode derived from compile's, g reruns the buffer's run in that mode"
  (let ([mine-buffer (runs:start-for-user "*mine*" "echo mine" (processes:options [directory "~/"]) mine)])
    (ended mine-buffer)
    (layout:switch-to-buffer mine-buffer)
    (test-user:press! "g")
    (ended mine-buffer)
    (check-equal? (list mine "mine") (list (modes:major-mode mine-buffer) (output mine-buffer)))))

(test "compile in an ended run's buffer runs in that run's folder"
  (let ([elsewhere (runs:start-for-user "*elsewhere*" "true" (processes:options [directory "~/other"]))])
    (ended elsewhere)
    (layout:switch-to-buffer elsewhere)
    (run shell-commands:compile "pwd")
    (ended (compilation))
    (check-equal? (shell-commands-test:home-path "other") (output (compilation)))))

(commands:define-command (project-compile)
  "Runs compile in a project's root, in a buffer of the project's own."
  (let ([root (shell-commands-test:home-path "proj/")])
    (options:with ([files:directory-override (cons (buffers:current) root)]
                   [shell-commands:compile-buffer-name (lambda () (string-append "*compilation " root "*"))])
      (commands:run shell-commands:compile))))

(test "a command binds files:directory-override and the build buffer's name for the commands it runs"
  (let ([root (shell-commands-test:home-path "proj/")])
    (layout:switch-to-buffer bar)
    (test-user:press! "M-x")
    (test-user:type! "project-compile")
    (test-user:press! "RET C-a C-k")
    (test-user:type! "pwd")
    (test-user:press! "RET")
    (let ([project-build (buffers:find (string-append "*compilation " root "*"))])
      (ended project-build)
      (check-equal? (shell-commands-test:home-path "proj") (output project-build))
      (options:with ([files:directory-override (cons bar root)]
                     [shell-commands:compile-buffer-name (lambda () (string-append "*compilation " root "*"))])
        (run shell-commands:recompile #f))
      (ended project-build)
      (check-equal? "~/proj/" (shell-commands-test:header-folder project-build)))
    (options:with ([files:directory-override (cons bar (shell-commands-test:home-path "proj"))])
      (run shell-commands:shell-command "pwd" #f))
    (check-equal? (shell-commands-test:home-path "proj") (shell-commands-test:message))))

(test "a reload of buffers brings an ended build back in runs:mode; the first g starts it in compile's mode without saving, the next saves"
  (options:set! shell-commands:compile-command "echo built")
  (run shell-commands:compile "echo reloaded")
  (ended (compilation))
  ;; A local value a mode hook sets while a key's command runs is the
  ;; key's owner's, not the hook entry's plugin's, so the reload finds it
  ;; holding a command of an unloaded plugin and takes it back loudly.
  (check (for-all warning? (shell-commands-test:reports-during (lambda () (reload-modules! '((buffers)))))))
  (let ([build (compilation)] [before saved])
    (check-equal? 'runs:mode (modes:major-mode build))
    (layout:switch-to-buffer build)
    (test-user:press! "g")
    (ended build)
    (check-equal? '(shell-commands:compilation-mode 0) (list (modes:major-mode build) (- saved before)))
    (test-user:press! "g")
    (ended build)
    (check-equal? 1 (- saved before))))
