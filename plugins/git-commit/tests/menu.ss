(import (tuna) (test) (test-user) (options) (modes) (buffers) (document) (views) (layout) (layout-split) (editing) (files) (ui)
        (git) (git-mode) (git-status) (with-editor) (git-commit) (transient-test) (git-status-test) (git-test repositories))

(define repo (git-status-test:fresh! "repo"))

(define git! git-test/repositories:git!)

(define (log) (git-status-test:git-out "repo" "log" "--format=%s"))

(define (first-line s) (let loop ([i 0]) (if (or (= i (string-length s)) (char=? #\newline (string-ref s i))) (substring s 0 i) (loop (+ i 1)))))

(define (message!) (git-status-test:wait-until-shown "COMMIT_EDITMSG"))

(define (running-arguments) (git:command-arguments (git:running repo)))

(define (committer-date) (string->number (first-line (git-status-test:git-out "repo" "log" "-1" "--format=%ct"))))

(define (finish! m text)
  (buffers:replace! m 1 1 text)
  (git-status-test:press! "C-c C-c"))

(define (arguments-group) (cadr (transient-test:menu)))

(define (arguments-with in)
  (list "Arguments"
        (list "- a" "Stage all modified and deleted files" (if (member "--all" in) "*--all" "--all"))
        (list "- e" "Allow empty commit" "--allow-empty")
        (list "- v" "Show diff of changes to be committed" "*--verbose")
        (list "- n" "Disable hooks" "--no-verify")
        (list "- R" "Claim authorship and reset author date" "--reset-author")
        (list "- A" "Override the author" (let ([a (find (lambda (x) (and (> (string-length x) 9) (string=? "--author=" (substring x 0 9)))) in)])
                                            (if a (string-append "*" a) "--author=")))))

(test "c shows the commit menu, with Magit's groups and keys, its arguments starting from git-commit:arguments"
  (git-status-test:press! "c")
  (check-equal? (list "Commit" (arguments-with '()) '("Create" ("c" "Commit")) '("Edit HEAD" ("e" "Extend") ("a" "Amend") ("w" "Reword")))
                (transient-test:menu)))

(test "a switch toggles its argument; -A reads an author and sets --author=; C-g closes the menu"
  (git-status-test:press! "- a")
  (check-equal? (arguments-with '("--all")) (arguments-group))
  (git-status-test:press! "- a")
  (git-status-test:answer! "Ada <ada@example.org>")
  (git-status-test:press! "- A")
  (check-equal? (list '("Author: ") (arguments-with '("--author=Ada <ada@example.org>"))) (list (git-status-test:take-asked!) (arguments-group)))
  (git-status-test:press! "- A")
  (git-status-test:press! "C-g")
  (check-equal? #f (transient-test:menu)))

(test "c c with something staged runs git commit --verbose; git's message file opens in the selected view in git-commit:mode, its diff folded"
  (git-status-test:take-said!)
  (test-user:press! "c c")
  (let ([m (message!)])
    (check-equal? '(#t #t modes:fundamental)
                  (list (buffers:with-buffer m (with-editor:mode)) (buffers:with-buffer m (git-commit:mode)) (modes:major-mode m)))
    (check-equal? '("Type C-c C-c to finish, C-c C-k to cancel" "Type C-c C-c to finish, C-c C-k to cancel, and M-p and M-n to recover older messages"
                    "Diffing changes to be committed (C-g to abort diffing)")
                  (git-status-test:take-said!))
    (check-equal? '("commit" "--verbose") (running-arguments))
    (check (pair? (views:folds-at (git-status-test:view) (- (document:length (buffers:document m)) 2))))
    (finish! m "Commit b\n")
    (check-equal? '("Commit b\nlong\nSecond commit\nFirst commit\n" "*git: repo*" ("Wrote ~/repo/.git/COMMIT_EDITMSG" "Git finished") "Commit b")
                  (list (log) (git-status-test:shown-buffer) (git-status-test:take-said!) (car (git-commit:messages))))
    (check (member "Unmerged into origin/main (3)" (git-status-test:status)))))

(test "c c with nothing staged and unstaged changes asks; n does nothing, y commits everything with --all"
  (git-status-test:answer! #f)
  (git-status-test:press! "c c")
  (check-equal? '(("Nothing staged.  Commit all uncommitted changes? ") "*git: repo*") (list (git-status-test:take-asked!) (git-status-test:shown-buffer)))
  (git-status-test:answer! #t)
  (test-user:press! "c c")
  (let ([m (message!)])
    (check-equal? '(("Nothing staged.  Commit all uncommitted changes? ") ("commit" "--verbose" "--all"))
                  (list (git-status-test:take-asked!) (running-arguments)))
    (finish! m "Everything\n")
    (check-equal? "?? new.txt\n" (git-status-test:short "repo"))))

(test "with nothing to commit c c raises; --allow-empty commits without asking"
  (delete-file (git-status-test:path "repo/new.txt"))
  (git-mode:refresh-repository repo)
  (check-equal? '((git-commit:create "Nothing staged (or unstaged)")) (git-status-test:press-reporting! "c c"))
  (test-user:press! "c - e c")
  (finish! (message!) "Empty\n")
  (check-equal? '(() "Empty") (list (git-status-test:take-asked!) (first-line (log)))))

(test "c a amends, the message opening with HEAD's message and a Date comment; C-c C-k cancels, saying Commit canceled. Message saved"
  (git-test/repositories:write-file! "repo/a.py" "amend\n")
  (git! "repo" "add" "a.py")
  (git-status-test:take-said!)
  (test-user:press! "c a")
  (let* ([m (message!)] [t (document:text (buffers:document m))])
    (check-equal? "Empty\n" (substring t 0 6))
    (check (git-status-test:contains? t "# Date:"))
    (git-status-test:press! "C-c C-k")
    (check-equal? "Commit canceled. Message saved" (car (reverse (git-status-test:take-said!))))))

(test "c w rewords HEAD's message alone"
  (test-user:press! "c w")
  (let ([m (message!)])
    (check-equal? '("commit" "--amend" "--only" "--allow-empty" "--verbose") (running-arguments))
    (buffers:replace! m 1 6 "Reworded")
    (git-status-test:press! "C-c C-c")
    (check-equal? '("Reworded" "M  a.py\n") (list (first-line (log)) (git-status-test:short "repo" "a.py")))))

(test "c e extends HEAD with the staged changes, opening nothing; git-commit:extend-override-date? #f keeps HEAD's committer date, and C-u inverts it"
  (git-test/repositories:run! "repo" "env" "GIT_COMMITTER_DATE=1600000000 +0000" "git" "commit" "-q" "--amend" "--no-edit")
  (options:set! git-commit:extend-override-date? #f)
  (git-status-test:take-said!)
  (git-status-test:press! "c e")
  (check-equal? '(("Git finished") "" 1600000000 "*git: repo*")
                (list (git-status-test:take-said!) (git-status-test:short "repo" "a.py") (committer-date) (git-status-test:shown-buffer)))
  (git-test/repositories:write-file! "repo/a.py" "extended\n")
  (git! "repo" "add" "a.py")
  (git-status-test:press! "c C-u e")
  (check (> (committer-date) 1600000000))
  (options:unset! git-commit:extend-override-date?))

(test "c w keeps HEAD's committer date while git-commit:reword-override-date? is #f"
  (git-test/repositories:run! "repo" "env" "GIT_COMMITTER_DATE=1600000000 +0000" "git" "commit" "-q" "--amend" "--no-edit")
  (options:set! git-commit:reword-override-date? #f)
  (test-user:press! "c w")
  (message!)
  (git-status-test:press! "C-c C-c")
  (check-equal? 1600000000 (committer-date))
  (options:unset! git-commit:reword-override-date?)
  (check-equal? '(now keep) (list (git-commit:committer-date now) (git-commit:committer-date keep))))

(test "amending, extending or rewording a commit of a published branch asks first, and n aborts"
  (options:set! git-commit:published-branches '("origin/main"))
  (git! "repo" "push" "-q" "origin" "main")
  (git-status-test:answer! #f)
  (check-equal? '((git-commit "Abort")) (git-status-test:press-reporting! "c w"))
  (check-equal? '(("This commit has already been published to origin/main.\nDo you really want to modify it? ") "*git: repo*")
                (list (git-status-test:take-asked!) (git-status-test:shown-buffer)))
  (options:unset! git-commit:published-branches))

(test "git-commit:ask-to-stage refuse raises Nothing staged; stage commits everything without asking"
  (git-test/repositories:write-file! "repo/a.py" "h\n")
  (git-mode:refresh-repository repo)
  (options:set! git-commit:ask-to-stage (git-commit:staging refuse))
  (check-equal? '((git-commit:create "Nothing staged")) (git-status-test:press-reporting! "c c"))
  (options:set! git-commit:ask-to-stage (git-commit:staging stage))
  (test-user:press! "c c")
  (message!)
  (check-equal? '(() ("commit" "--verbose" "--all")) (list (git-status-test:take-asked!) (running-arguments)))
  (git-status-test:press! "C-c C-k")
  (options:unset! git-commit:ask-to-stage))

(test "amending before the first commit is git's refusal, said as a Git error"
  (git! "" "init" "-q" "-b" "main" "empty")
  (git-test/repositories:write-file! "empty/x" "x\n")
  (git! "empty" "add" "x")
  (git-status:show (git:find-repository (git-status-test:path "empty")))
  (git-status-test:settle!)
  (git-status-test:take-said!)
  (git-status-test:press! "c a")
  (check-equal? '("Git error: You have nothing to amend. [Type $ for details]") (git-status-test:take-said!)))
