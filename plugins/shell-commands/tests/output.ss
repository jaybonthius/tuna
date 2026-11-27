(import (tuna) (test) (test-runner) (test-user) (hooks) (tables) (modes) (buffers) (layout) (commands) (files) (dired)
        (shell-commands) (shell-commands-test))

(define run shell-commands-test:run)

(define listed (shell-commands-test:home-path "listed/"))

(define (out) (buffers:find "*Shell Command Output*"))

(define (revert-function b) (buffers:with-buffer b (buffers:revert-function)))

(shell-commands-test:folder! "listed")
(shell-commands-test:write-file! "listed/a.txt" "a\n")

(test "a command runs in files:directory of the current buffer, a folder listing's folder included"
  (layout:switch-to-buffer (dired:visit listed))
  (run shell-commands:shell-command "pwd" #f)
  (check-equal? (shell-commands-test:home-path "listed") (shell-commands-test:message)))

(test "*Shell Command Output*'s folder is that of the command it holds, after edits, a rename and a reload of shell-commands"
  (run shell-commands:shell-command "ls" #f)
  (check-equal? (list "a.txt\n" listed) (list (shell-commands-test:text (out)) (files:directory (out))))
  (layout:switch-to-buffer (out))
  (run shell-commands:shell-command "pwd" #f)
  (check-equal? (shell-commands-test:home-path "listed") (shell-commands-test:message))
  (let ([kept (out)])
    (buffers:rename! kept "kept output")
    (layout:switch-to-buffer kept)
    (run shell-commands:shell-command "pwd" #f)
    (check-equal? (shell-commands-test:home-path "listed") (shell-commands-test:message))
    (reload-modules! '((shell-commands)))
    (check-equal? (list listed #t) (list (files:directory kept) (eq? (revert-function kept) shell-commands:shell-command-again)))))

(test "buffers:revert-buffer there runs the command again, through shell-command-again"
  (layout:switch-to-buffer (out))
  (run shell-commands:shell-command "ls" #f)
  (shell-commands-test:write-file! "listed/b.txt" "b\n")
  (run buffers:revert-buffer)
  (check-equal? "a.txt\nb.txt\n" (shell-commands-test:text (out))))

(test "it is a text buffer the user may edit, so g types there, and M-x does not offer shell-command-again"
  (layout:switch-to-buffer (out))
  (test-user:press! "g")
  (check-equal? '("ga.txt\nb.txt\n" #t ())
                (list (shell-commands-test:text (out)) (buffers:modified? (out))
                      (tables:ref commands:command-modes shell-commands:shell-command-again #f))))

(test "a write marks the buffer unmodified, so killing it asks nothing"
  (run shell-commands:shell-command "echo x" #f)
  (check-equal? #f (buffers:modified? (out))))

(test "a major mode set there drops the revert function; the folder stays"
  (let ([b (out)])
    (buffers:with-buffer b (modes:set-major-mode modes:fundamental b))
    (check-equal? #f (eq? (revert-function b) shell-commands:shell-command-again))
    (check-equal? listed (files:directory b))))

(test "shell-command-again raises in a buffer that holds no line"
  (layout:switch-to-buffer (buffers:make "plain" "text\n"))
  (check-equal? '((shell-commands:shell-command-again "the buffer holds no command line" ()))
                (shell-commands-test:reported (lambda () (run shell-commands:shell-command-again)))))

(test "shell-commands' entry in files:directory-finders answers only for a buffer whose root holds a line"
  (let ([file (files:visit "~/listed/a.txt")])
    (check-equal? listed (files:directory file))
    (check (for-all (lambda (answer) (or (not answer) (string=? answer listed)))
                    (map (lambda (entry) (entry file)) (hooks:entries files:directory-finders))))))
