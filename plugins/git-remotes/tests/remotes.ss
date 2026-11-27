(import (tuna) (test) (test-user) (test-runner) (options) (buffers) (document) (views) (layout) (layout-split) (editing) (files)
        (ui) (git) (git-mode) (git-status) (with-editor) (git-commit) (git-remotes) (transient-test) (git-status-test)
        (git-test repositories))

(define repo (git-status-test:fresh! "repo"))

(define git! git-test/repositories:git!)

(define (last-command) (git:command-arguments (car (reverse (git:commands repo)))))

(define (out . arguments) (apply git-status-test:git-out "repo" arguments))

(define (unmerged?)
  (exists (lambda (l) (and (> (string-length l) 8) (string=? "Unmerged" (substring l 0 8)))) (git-status-test:status)))

(define push-arguments
  '("Arguments" ("- f" "Force with lease" "--force-with-lease") ("- F" "Force" "--force") ("- h" "Disable hooks" "--no-verify")
    ("- n" "Dry run" "--dry-run") ("- T" "Include all tags" "--tags") ("- t" "Include related annotated tags" "--follow-tags")))

;; A menu shows at once and reads its branch in a task of its own, with
;; git queries that no event marks, so this waits for what it shows.
(define (menu-shows! keys expected)
  (git-status-test:press! keys)
  (test-runner:wait-until (lambda () (equal? expected (transient-test:menu)))))

(define (push! keys) (git-status-test:press! keys) (list (git-status-test:take-asked!) (last-command)))

(test "P shows the push menu, its targets naming the push-remote's branch and the upstream when set"
  (menu-shows! "P" (list "Push" push-arguments '("Push main to" ("p" "pushRemote, setting that") ("u" "origin/main") ("e" "elsewhere"))))
  (git-status-test:press! "C-g"))

(test "P u pushes to the upstream with git-mode:start, saying Git finished, and the commits it pushed leave Unmerged into"
  (git-status-test:take-said!)
  (git-status-test:press! "P u")
  (check-equal? '(("push" "-v" "origin" "main:refs/heads/main") ("Git finished") ("Head:     main long" "Merge:    origin/main long") #f)
                (list (last-command) (git-status-test:take-said!) (list-head (git-status-test:status) 2) (unmerged?))))

(test "P p with no push-remote reads one, sets it and pushes; with one it pushes without asking; C-u asks again"
  (git-status-test:answer! "origin")
  (check-equal? '(("Set branch.main.pushRemote and push there (default origin): ") ("push" "-v" "origin" "refs/heads/main:refs/heads/main"))
                (push! "P p"))
  (check-equal? "origin\n" (out "config" "branch.main.pushRemote"))
  (check-equal? '() (car (push! "P p")))
  (git-status-test:answer! "origin")
  (check-equal? '("Set branch.main.pushRemote and push there (default origin): ") (car (push! "P C-u p"))))

(test "P u with no upstream reads one and pushes with --set-upstream; P e reads a remote branch and pushes there"
  (git! "repo" "checkout" "-q" "-b" "topic")
  (git-mode:refresh-repository repo)
  (git-status-test:answer! "origin/topic")
  (check-equal? '(("Set upstream of topic and push there: ") ("push" "-v" "--set-upstream" "origin" "topic:refs/heads/topic"))
                (push! "P u"))
  (check-equal? "origin/topic\n" (out "rev-parse" "--abbrev-ref" "topic@{upstream}"))
  (git-status-test:answer! "origin/elsewhere")
  (check-equal? '(("Push topic to: ") ("push" "-v" "origin" "topic:refs/heads/elsewhere")) (push! "P e")))

(test "git-remotes:push-arguments sets the switches the push menu starts with"
  (options:set! git-remotes:push-arguments '("--force-with-lease"))
  (menu-shows! "P" (list "Push" (cons "Arguments" (cons '("- f" "Force with lease" "*--force-with-lease") (cddr push-arguments)))
                         '("Push topic to" ("p" "pushRemote, setting that") ("u" "origin/topic") ("e" "elsewhere"))))
  (git-status-test:press! "u")
  (options:unset! git-remotes:push-arguments)
  (check-equal? '("push" "-v" "--force-with-lease" "origin" "topic:refs/heads/topic") (last-command)))

(test "f shows the fetch menu; f u fetches the upstream's remote, and the commits not pulled show; f a fetches every remote; f e reads a remote"
  (git! "repo" "checkout" "-q" "main")
  (git! "" "clone" "-q" "origin-repo.git" "o")
  (git! "o" "config" "user.name" "o")
  (git! "o" "config" "user.email" "o@x")
  (git-test/repositories:write-file! "o/o.txt" "o\n")
  (git! "o" "add" "o.txt")
  (git! "o" "commit" "-qm" "Origin commit")
  (git! "o" "push" "-q")
  (git-mode:refresh-repository repo)
  (menu-shows! "f" '("Fetch" ("Arguments" ("- p" "Prune deleted branches" "--prune") ("- t" "Fetch all tags" "--tags") ("- F" "Force" "--force"))
                     ("Fetch from" ("p" "origin") ("u" "origin") ("e" "elsewhere") ("a" "all remotes"))))
  (git-status-test:press! "u")
  (check-equal? '(("fetch" "origin") #t) (list (last-command) (and (member "Unpulled from origin/main (1)…" (git-status-test:status)) #t)))
  (check-equal? '(() ("fetch" "--all")) (push! "f a"))
  (git-status-test:answer! "origin")
  (check-equal? '(("Fetch remote: ") ("fetch" "origin")) (push! "f e")))

(test "F u pulls from the upstream with with-editor's environment, and buffers of files it changed are reverted"
  (git! "repo" "stash" "-q" "-u")
  (git-test/repositories:write-file! "repo/o.txt" "")
  (let ([o (files:visit (git-status-test:path "repo/o.txt"))])
    (delete-file (git-status-test:path "repo/o.txt"))
    (menu-shows! "F" '("Pull" ("Arguments" ("- f" "Fast-forward only" "--ff-only") ("- r" "Rebase local commits" "--rebase") ("- F" "Force" "--force"))
                       ("Pull into main from" ("p" "origin/main") ("u" "origin/main") ("e" "elsewhere"))))
    (git-status-test:take-said!)
    (git-status-test:press! "u")
    (check-equal? '(("pull" "origin" "refs/heads/main") ("Git finished") "o\n")
                  (list (last-command) (git-status-test:take-said!) (document:text (buffers:document o))))))

(test "a pull that merges opens MERGE_MSG, and C-c C-c makes the merge commit"
  (git-test/repositories:write-file! "o/o.txt" "o\nagain\n")
  (git! "o" "commit" "-qam" "Origin again")
  (git! "o" "push" "-q")
  (git-test/repositories:write-file! "repo/local.txt" "l\n")
  (git! "repo" "add" "local.txt")
  (git! "repo" "commit" "-qm" "local")
  (git! "repo" "config" "pull.rebase" "false")
  (test-user:press! "F u")
  (git-status-test:wait-until-shown "MERGE_MSG")
  (git-status-test:press! "C-c C-c")
  (check-equal? "Merge branch 'main' of ../origin-repo\n" (out "log" "-1" "--format=%s"))
  (check-equal? (out "rev-parse" "HEAD^2") (out "rev-parse" "origin/main")))

(test "F p pulls from the push-remote; F e from a branch read; F u with no upstream reads one and sets it"
  (check-equal? '(() ("pull" "origin" "refs/heads/main")) (push! "F p"))
  (git-status-test:answer! "origin/main")
  (check-equal? '(("Pull from: ") ("pull" "origin" "refs/heads/main")) (push! "F e"))
  (git! "repo" "checkout" "-q" "-b" "lone")
  (git-status-test:answer! "origin/main")
  (check-equal? '("Set upstream of lone and pull from there: ") (car (push! "F u")))
  (check-equal? "origin/main\n" (out "rev-parse" "--abbrev-ref" "lone@{upstream}")))

(test "git-remotes:pull-arguments sets the switches the pull menu starts with, and a pull adds --rebase when branch.BRANCH.rebase is true"
  (git! "repo" "checkout" "-q" "main")
  (options:set! git-remotes:pull-arguments '("--ff-only"))
  (git! "repo" "config" "branch.main.rebase" "true")
  (menu-shows! "F" '("Pull" ("Arguments" ("- f" "Fast-forward only" "*--ff-only") ("- r" "Rebase local commits" "--rebase") ("- F" "Force" "--force"))
                     ("Pull into main from" ("p" "origin/main") ("u" "origin/main") ("e" "elsewhere"))))
  (git-status-test:press! "u")
  (options:unset! git-remotes:pull-arguments)
  (git! "repo" "config" "--unset" "branch.main.rebase")
  (check-equal? '("pull" "--ff-only" "--rebase" "origin" "refs/heads/main") (last-command)))

(test "a failure says Git error with git's last fatal or error line, and the status buffer shows it"
  (git! "repo" "remote" "set-url" "origin" "/nowhere")
  (git-status-test:take-said!)
  (git-status-test:press! "f u")
  (check-equal? '(("Git error: Could not read from remote repository. [Type $ for details]")
                  "GitError! Could not read from remote repository.  [Type $ for details]")
                (list (git-status-test:take-said!) (car (git-status-test:status)))))

(test "git asks for no credentials: a remote that would ask fails at once"
  (check-equal? '(("GIT_TERMINAL_PROMPT" . "0") ("GIT_SSH_COMMAND" . "ssh -o BatchMode=yes"))
                (map (lambda (v) (assoc v (git:environment))) '("GIT_TERMINAL_PROMPT" "GIT_SSH_COMMAND"))))

(test "keys work while a command runs, and C-g does not stop it"
  (git-test/repositories:write-file! "repo/.git/hooks/pre-push" "#!/bin/sh\nsleep 1\n")
  (git-test/repositories:run! "repo" "chmod" "+x" ".git/hooks/pre-push")
  (git! "repo" "remote" "set-url" "origin" "../origin-repo.git")
  (test-user:press! "P u")
  (test-runner:wait-until (lambda () (git:running repo)))
  (test-user:press! "C-g n")
  (check (git:command? (git:running repo)))
  (git-status-test:settle!)
  (check-equal? '(0 ("push" "-v" "origin" "main:refs/heads/main"))
                (list (git:command-exit (car (reverse (git:commands repo)))) (last-command))))

(test "a menu shown in another repository shows placeholders until its branch is read, never the last menu's branch"
  (menu-shows! "P" (list "Push" push-arguments '("Push main to" ("p" "origin/main") ("u" "origin/main") ("e" "elsewhere"))))
  (git-status-test:press! "C-g")
  (git! "" "init" "-q" "-b" "side" "side")
  (git! "side" "-c" "user.name=s" "-c" "user.email=s@x" "commit" "-q" "--allow-empty" "-m" "one")
  (git-status:show (git:find-repository (git-status-test:path "side")))
  (git-status-test:settle!)
  (test-user:press! "P")
  (check-equal? '("Push HEAD to" ("p" "pushRemote, setting that") ("u" "@{upstream}, setting it") ("e" "elsewhere"))
                (car (reverse (transient-test:menu))))
  (test-runner:wait-until (lambda () (equal? "Push side to" (car (car (reverse (transient-test:menu)))))))
  (check-equal? '("Push side to" ("p" "pushRemote, setting that") ("u" "@{upstream}, setting it") ("e" "elsewhere"))
                (car (reverse (transient-test:menu))))
  (git-status-test:press! "C-g"))
