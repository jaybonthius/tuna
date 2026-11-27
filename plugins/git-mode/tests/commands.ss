(import (tuna) (test) (test-user) (test-runner) (options) (modes) (buffers) (views) (layout) (layout-split) (editing) (files) (ui)
        (git) (git-mode) (git-status) (git-status-test) (git-test repositories))

(define repo (git-status-test:fresh! "repo"))

(define status-view (git-status-test:view))

(define (command-lines)
  (filter (lambda (l) (and (> (string-length l) 7) (string=? " git … " (substring l 3 10)))) (git-status-test:status)))

(test "$ shows the command log in another view and selects it: a section per command, its exit status in 3 columns, then git … and the arguments; a failed command's output shows"
  (git-status-test:go-to-section! '(file . "a.py") '(unstaged . #f))
  (git-status-test:press! "s")
  (git:run repo '("tag" "v1"))
  (check-raises git:failed-condition? (git:run repo '("checkout" "nowhere")))
  (git-status-test:take-said!)
  (git-status-test:press! "$")
  (check-equal? '("*git-commands: repo*" #f git-mode:commands-mode)
                (list (git-status-test:shown-buffer) (eq? status-view (git-status-test:view)) (modes:major-mode (views:buffer (git-status-test:view)))))
  (check-equal? '("  0 git … add --pathspec-from-file=- --pathspec-file-nul" "  0 git … tag v1" "  1 git … checkout nowhere"
                  "error: pathspec 'nowhere' did not match any file(s) known to git")
                (git-status-test:status))
  (check-equal? '(git-mode:commands-mode git-mode:mode ui:section-mode modes:special) (modes:ancestry git-mode:commands-mode)))

(test "g is undefined in the log, which follows the commands itself"
  (check-equal? '("g is undefined") (git-status-test:press-reporting-messages! "g"))
  (git:run repo '("tag" "v2"))
  (git-status-test:settle!)
  (check-equal? "  0 git … tag v2" (car (reverse (git-status-test:status)))))

(test "while a command runs the status line of each view of the repository's Git buffers shows it; k asks Kill process? and stops it, which ends with -1"
  (git-test/repositories:write-file! "repo/.git/hooks/pre-commit" "#!/bin/sh\nsleep 30\n")
  (git-test/repositories:run! "repo" "chmod" "+x" ".git/hooks/pre-commit")
  (let ([slow (git-mode:start repo '("commit" "-m" "slow") (lambda (c) (void)))])
    (test-runner:wait-until (lambda () (git:running repo)))
    (test-user:press! "M->")
    (check-equal? "    git … commit -m slow" (git-status-test:point-line))
    (check-equal? '("git commit -m slow…" "git commit -m slow…")
                  (list (git-mode:show-running status-view) (git-mode:show-running (git-status-test:view))))
    (git-status-test:answer! #t)
    (test-user:press! "k")
    (test-runner:wait-until (lambda () (git:command-exit slow)))
    (git-status-test:settle!)
    (check-equal? '(("Kill process?") -1 " -1 git … commit -m slow")
                  (list (git-status-test:take-asked!) (git:command-exit slow) (git-status-test:point-line)))
    (check-equal? '("Git error: git failed [Type $ for details]") (git-status-test:take-said!))
    (check-equal? #f (git-mode:show-running status-view))))

(test "k on a command that has ended raises Process isn't running"
  (check-equal? '((git-mode:stop-command "Process isn't running")) (git-status-test:press-reporting! "k")))

(test "the log shows the git:command-log-size commands git keeps"
  (options:set! git:command-log-size 3)
  (git:run repo '("tag" "v3"))
  (git-status-test:settle!)
  (check-equal? '(3 3) (list (length (git:commands repo)) (length (command-lines))))
  (options:unset! git:command-log-size))

(test "q in the log quits its view and selects the view it was shown from"
  (git-status-test:press! "q")
  (check-equal? '("*git: repo*" #t) (list (git-status-test:shown-buffer) (eq? status-view (git-status-test:view)))))

(test "a command started with git-mode:start says Git finished; one a caller waits for, such as staging, says nothing"
  (git-status-test:take-said!)
  (git-status-test:go-to-section! '(file . "b.txt") '(unstaged . #f))
  (git-status-test:press! "s")
  (check-equal? '() (git-status-test:take-said!))
  (check (git:command? (git-mode:start repo '("tag" "v4") (lambda (c) (void)))))
  (git-status-test:settle!)
  (check-equal? '("Git finished") (git-status-test:take-said!)))

(test "git-mode:last-error is the last failure's summary, cleared by a success; a canceled command is no error and says nothing"
  (check-equal? #f (git-mode:last-error repo))
  (let ([failing (git-mode:start repo '("checkout" "nowhere") (lambda (c) (git:set-command-canceled! c)))])
    (test-runner:wait-until (lambda () (git:command-exit failing)))
    (git-status-test:settle!)
    (check-equal? '(#f ()) (list (git-mode:last-error repo) (git-status-test:take-said!))))
  (git-mode:start repo '("checkout" "nowhere") (lambda (c) (void)))
  (git-status-test:settle!)
  (check-equal? "pathspec 'nowhere' did not match any file(s) known to git" (git-mode:last-error repo))
  (git:run repo '("tag" "v5"))
  (check-equal? #f (git-mode:last-error repo))
  (git-status-test:take-said!))

(test "call-with-failures-reported stops quietly on a failure of the log, which is said, and raises a failed query"
  (check-equal? 'stopped
    (begin (git-mode:call-with-failures-reported repo (lambda () (git:run repo '("checkout" "nowhere")))) 'stopped))
  (git-status-test:settle!)
  (check-equal? '("Git error: pathspec 'nowhere' did not match any file(s) known to git [Type $ for details]") (git-status-test:take-said!))
  (check-raises git:failed-condition? (git-mode:call-with-failures-reported repo (lambda () (git:query repo '("rev-parse" "--verify" "nothing"))))))
