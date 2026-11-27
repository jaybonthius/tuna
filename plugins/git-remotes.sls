#!tuna
(import (git-mode) (git) (with-editor) (transient) (keys) (commands) (ask) (options))

(define %self (current-owner))

(define (%strings? v) (and (list? v) (for-all string? v)))

(options:define-option push-arguments '() %strings? "The arguments the push menu starts with.")

(options:define-option pull-arguments '() %strings? "The arguments the pull menu starts with.")

;; A menu's descriptions are drawn after every batch and must not wait
;; for git, so they read the branch and its remotes from what a task
;; started with the menu found; the menu shows at once, so the key typed
;; next reaches it.
(define-record-type %branch-state
  (sealed #t)
  (fields branch upstream push-remote))

(define %state #f)

;; A task started for an earlier menu can end after a later menu's, so
;; only the last menu's repository may set the state.
(define %menu-repository #f)

(define (%branch-of repository)
  (or (git:status-branch (git:status repository))
      (error 'git-remotes "No branch is checked out")))

(define (%read-state! repository)
  (let* ([branch (git:status-branch (git:status repository))]
         [state (make-%branch-state branch (and branch (git:upstream repository branch))
                                    (and branch (git:push-remote repository branch)))])
    (when (eq? repository %menu-repository)
      (set! %state state))))

(define (%branch-name) (or (and %state (%branch-state-branch %state)) "HEAD"))

(define (%push-description)
  (let ([remote (and %state (%branch-state-push-remote %state))])
    (if remote (string-append remote "/" (%branch-name)) "pushRemote, setting that")))

(define (%upstream-description)
  (or (and %state (%branch-state-upstream %state)) "@{upstream}, setting it"))

(define (%fetch-upstream-description)
  (let ([upstream (and %state (%branch-state-upstream %state))])
    (if upstream (%remote-of upstream) "@{upstream}, setting it")))

(define (%remote-of remote-branch)
  (let loop ([i 0])
    (cond
      [(fx= i (string-length remote-branch)) remote-branch]
      [(char=? (string-ref remote-branch i) #\/) (substring remote-branch 0 i)]
      [else (loop (fx+ i 1))])))

(define (%branch-of-remote-branch remote-branch)
  (let loop ([i 0])
    (cond
      [(fx= i (string-length remote-branch)) remote-branch]
      [(char=? (string-ref remote-branch i) #\/) (substring remote-branch (fx+ i 1) (string-length remote-branch))]
      [else (loop (fx+ i 1))])))

(transient:define-menu push-menu "Pushing the branch."
  (title "Push")
  (arguments push-arguments))

(transient:define-menu pull-menu "Pulling into the branch."
  (title "Pull")
  (arguments pull-arguments))

(transient:define-menu fetch-menu "Fetching from remotes."
  (title "Fetch"))

(define (%check who arguments)
  (unless (%strings? arguments)
    (assertion-violation who "not a list of strings" arguments)))

(define (%read-push-remote repository branch)
  (let* ([remotes (git:remotes repository)]
         [default (or (git:config repository "remote.pushDefault") (and (member "origin" remotes) "origin") (and (pair? remotes) (car remotes)))]
         [answer (ask:line-with-candidates
                   (string-append "Set branch." branch ".pushRemote and push there"
                                  (if default (string-append " (default " default ")") "") ": ")
                   remotes default)]
         [remote (if (and (string=? answer "") default) default answer)])
    (git:set-config! repository (string-append "branch." branch ".pushRemote") remote)
    remote))

(define (%push-remote! who repository branch)
  (or (and (not (commands:prefix-argument)) (git:push-remote repository branch))
      (%read-push-remote repository branch)))

(define (%read-upstream repository branch verb)
  (let* ([candidates (git:remote-branches repository)]
         [default (let ([d (string-append "origin/" branch)]) (and (member d candidates) d))]
         [answer (ask:line-with-candidates (string-append "Set upstream of " branch " and " verb " there: ") candidates default)])
    (if (and (string=? answer "") default) default answer)))

(define (%start! repository arguments)
  (git-mode:start repository arguments (lambda (command) (void)))
  (void))

(commands:define-command (push-to-push-remote [arguments (transient:arguments push-menu)])
  "Pushes the branch to the same-named branch of its push-remote, reading and setting the push-remote when it has none or with C-u."
  (%check 'git-remotes:push-to-push-remote arguments)
  (let* ([repository (git-mode:current-repository)] [branch (%branch-of repository)]
         [remote (%push-remote! 'git-remotes:push-to-push-remote repository branch)])
    (%start! repository (append '("push" "-v") arguments
                                (list remote (string-append "refs/heads/" branch ":refs/heads/" branch))))))

(commands:define-command (push-to-upstream [arguments (transient:arguments push-menu)])
  "Pushes the branch to its upstream, reading one and pushing with --set-upstream when it has none or with C-u."
  (%check 'git-remotes:push-to-upstream arguments)
  (let* ([repository (git-mode:current-repository)] [branch (%branch-of repository)]
         [upstream (and (not (commands:prefix-argument)) (git:upstream repository branch))])
    (if upstream
        (%start! repository (append '("push" "-v") arguments
                                    (list (%remote-of upstream) (string-append branch ":refs/heads/" (%branch-of-remote-branch upstream)))))
        (let ([target (%read-upstream repository branch "push")])
          (%start! repository (append '("push" "-v" "--set-upstream") arguments
                                      (list (%remote-of target) (string-append branch ":refs/heads/" (%branch-of-remote-branch target)))))))))

(define (%read-push-target)
  (let* ([repository (git-mode:current-repository)] [branch (%branch-of repository)])
    (ask:line-with-candidates (string-append "Push " branch " to: ") (git:remote-branches repository))))

(define (%read-pull-source)
  (ask:line-with-candidates "Pull from: " (git:remote-branches (git-mode:current-repository))))

(commands:define-command (push-elsewhere [target (%read-push-target)] [arguments (transient:arguments push-menu)])
  "Pushes the branch to the remote branch TARGET."
  (%check 'git-remotes:push-elsewhere arguments)
  (let* ([repository (git-mode:current-repository)] [branch (%branch-of repository)])
    (%start! repository (append '("push" "-v") arguments
                                (list (%remote-of target) (string-append branch ":refs/heads/" (%branch-of-remote-branch target)))))))

(define (%pull! repository arguments remote branch)
  (let* ([rebase? (equal? (git:config repository (string-append "branch." (%branch-of repository) ".rebase")) "true")]
         [arguments (if (and rebase? (not (member "--rebase" arguments))) (append arguments '("--rebase")) arguments)]
         [editing (with-editor:output-wrapper)])
    (git-mode:start repository (append '("pull") arguments (list remote (string-append "refs/heads/" branch)))
      (lambda (command) (when (with-editor:canceled? editing) (git:set-command-canceled! command)))
      (append (with-editor:environment "GIT_EDITOR") '(("GIT_MERGE_AUTOEDIT" . "yes")))
      editing)
    (void)))

(commands:define-command (pull-from-push-remote [arguments (transient:arguments pull-menu)])
  "Pulls from the push-remote's same-named branch, setting the push-remote as P p does."
  (%check 'git-remotes:pull-from-push-remote arguments)
  (let* ([repository (git-mode:current-repository)] [branch (%branch-of repository)]
         [remote (%push-remote! 'git-remotes:pull-from-push-remote repository branch)])
    (%pull! repository arguments remote branch)))

(define (%set-upstream! repository branch target)
  (git:run repository (list "branch" (string-append "--set-upstream-to=" target) branch)))

(commands:define-command (pull-from-upstream [arguments (transient:arguments pull-menu)])
  "Pulls from the upstream, reading and setting one when there is none or with C-u."
  (%check 'git-remotes:pull-from-upstream arguments)
  (let* ([repository (git-mode:current-repository)] [branch (%branch-of repository)]
         [upstream (or (and (not (commands:prefix-argument)) (git:upstream repository branch))
                       (let ([target (%read-upstream repository branch "pull from")])
                         (git-mode:call-with-failures-reported repository (lambda () (%set-upstream! repository branch target)))
                         target))])
    (%pull! repository arguments (%remote-of upstream) (%branch-of-remote-branch upstream))))

(commands:define-command (pull-elsewhere [source (%read-pull-source)] [arguments (transient:arguments pull-menu)])
  "Pulls from the remote branch SOURCE."
  (%check 'git-remotes:pull-elsewhere arguments)
  (%pull! (git-mode:current-repository) arguments (%remote-of source) (%branch-of-remote-branch source)))

(commands:define-command (fetch-from-push-remote [arguments (transient:arguments fetch-menu)])
  "Fetches the push-remote, setting it as P p does."
  (%check 'git-remotes:fetch-from-push-remote arguments)
  (let* ([repository (git-mode:current-repository)] [branch (%branch-of repository)])
    (%start! repository (append '("fetch") arguments (list (%push-remote! 'git-remotes:fetch-from-push-remote repository branch))))))

(commands:define-command (fetch-from-upstream [arguments (transient:arguments fetch-menu)])
  "Fetches the upstream's remote, setting the upstream when there is none."
  (%check 'git-remotes:fetch-from-upstream arguments)
  (let* ([repository (git-mode:current-repository)] [branch (%branch-of repository)]
         [upstream (or (and (not (commands:prefix-argument)) (git:upstream repository branch))
                       (let ([target (%read-upstream repository branch "fetch from")])
                         (git-mode:call-with-failures-reported repository (lambda () (%set-upstream! repository branch target)))
                         target))])
    (%start! repository (append '("fetch") arguments (list (%remote-of upstream))))))

(commands:define-command (fetch-elsewhere [remote (ask:line-with-candidates "Fetch remote: " (git:remotes (git-mode:current-repository)))]
                                          [arguments (transient:arguments fetch-menu)])
  "Fetches REMOTE."
  (%check 'git-remotes:fetch-elsewhere arguments)
  (%start! (git-mode:current-repository) (append '("fetch") arguments (list remote))))

(commands:define-command (fetch-all [arguments (transient:arguments fetch-menu)])
  "Fetches every remote."
  (%check 'git-remotes:fetch-all arguments)
  (%start! (git-mode:current-repository) (append '("fetch" "--all") arguments)))

(define (%show-menu! menu)
  (let ([repository (git-mode:current-repository)])
    (set! %state #f)
    (set! %menu-repository repository)
    (transient:show! menu)
    (call-as-owner %self (lambda () (spawn-task (lambda (restore) (%read-state! repository)))))))

(commands:define-command (push) "Shows the push menu." (%show-menu! push-menu))

(commands:define-command (pull) "Shows the pull menu." (%show-menu! pull-menu))

(commands:define-command (fetch) "Shows the fetch menu." (%show-menu! fetch-menu))

(transient:add! push-menu "Arguments"
  (transient:switch "- f" "Force with lease" "--force-with-lease")
  (transient:switch "- F" "Force" "--force")
  (transient:switch "- h" "Disable hooks" "--no-verify")
  (transient:switch "- n" "Dry run" "--dry-run")
  (transient:switch "- T" "Include all tags" "--tags")
  (transient:switch "- t" "Include related annotated tags" "--follow-tags"))
(transient:add! push-menu (lambda () (string-append "Push " (%branch-name) " to"))
  (transient:command "p" %push-description push-to-push-remote)
  (transient:command "u" %upstream-description push-to-upstream)
  (transient:command "e" "elsewhere" push-elsewhere))
(transient:add! pull-menu "Arguments"
  (transient:switch "- f" "Fast-forward only" "--ff-only")
  (transient:switch "- r" "Rebase local commits" "--rebase")
  (transient:switch "- F" "Force" "--force"))
(transient:add! pull-menu (lambda () (string-append "Pull into " (%branch-name) " from"))
  (transient:command "p" %push-description pull-from-push-remote)
  (transient:command "u" %upstream-description pull-from-upstream)
  (transient:command "e" "elsewhere" pull-elsewhere))
(transient:add! fetch-menu "Arguments"
  (transient:switch "- p" "Prune deleted branches" "--prune")
  (transient:switch "- t" "Fetch all tags" "--tags")
  (transient:switch "- F" "Force" "--force"))
(transient:add! fetch-menu "Fetch from"
  (transient:command "p" (lambda () (let ([r (and %state (%branch-state-push-remote %state))]) (or r "pushRemote, setting that"))) fetch-from-push-remote)
  (transient:command "u" %fetch-upstream-description fetch-from-upstream)
  (transient:command "e" "elsewhere" fetch-elsewhere)
  (transient:command "a" "all remotes" fetch-all))
(transient:add! git-mode:dispatch-menu #f
  (transient:command "f" "Fetch" fetch)
  (transient:command "F" "Pull" pull)
  (transient:command "P" "Push" push))
(keys:bind! git-mode:keymap "P" push)
(keys:bind! git-mode:keymap "F" pull)
(keys:bind! git-mode:keymap "f" fetch)
