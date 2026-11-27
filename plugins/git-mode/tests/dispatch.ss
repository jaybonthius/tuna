(import (tuna) (test) (test-user) (modes) (buffers) (views) (layout) (layout-split) (editing) (files) (git) (git-mode) (git-status)
        (git-commit) (git-remotes) (transient-test) (git-status-test) (git-test repositories))

(define repo (git-status-test:fresh! "repo"))

(define (menu-open?) (and (transient-test:menu) #t))

(define (git-buffer-names)
  (map buffers:name (filter (lambda (b) (modes:derived? (modes:major-mode b) git-mode:mode)) (buffers:all))))

(test "?, h and C-c C-c show the dispatch menu: Essential commands, then each Git menu and I, then Applying changes"
  (git-status-test:press! "?")
  (check-equal? '("Transient and dwim commands"
                  ("Essential commands" ("g" "Refresh current buffer") ("q" "Bury current buffer") ("TAB" "Toggle section at point")
                   ("RET" "Visit thing at point"))
                  (("I" "Init") ("c" "Commit") ("f" "Fetch") ("F" "Pull") ("P" "Push"))
                  ("Applying changes" ("s" "Stage") ("u" "Unstage") ("k" "Discard") ("S" "Stage all") ("U" "Unstage all")))
                (transient-test:menu))
  (git-status-test:press! "C-g")
  (for-each
    (lambda (keys)
      (git-status-test:press! keys)
      (check (menu-open?))
      (git-status-test:press! "C-g")
      (check (not (menu-open?))))
    '("h" "C-c C-c")))

(test "C-x M-g outside a repository raises Not inside a Git repository; inside one it shows the menu"
  (mkdir (git-status-test:path "plain"))
  (layout:switch-to-buffer (files:visit (git-status-test:path "plain/n.txt")))
  (check-equal? '((git-mode:current-repository "Not inside a Git repository")) (git-status-test:press-reporting! "C-x M-g"))
  (check (not (menu-open?)))
  (layout:switch-to-buffer (files:visit (git-status-test:path "repo/a.py")))
  (git-status-test:press! "C-x M-g")
  (check (menu-open?))
  (git-status-test:press! "C-g"))

(test "keys of Magit commands Tuna lacks are undefined in a Git buffer"
  (layout:switch-to-buffer (git-status-test:status-buffer))
  (check-equal? '("b is undefined" "z is undefined" "y is undefined")
                (apply append (map git-status-test:press-reporting-messages! '("b" "z" "y")))))

(test "q quits the view, showing the buffer it showed before; C-u q also kills the buffer"
  (layout:switch-to-buffer (files:visit (git-status-test:path "repo/a.py")))
  (git-status-test:press! "C-x 1")
  (git-status-test:press! "C-x g")
  (git-status-test:press! "q")
  (check-equal? '("a.py" #t) (list (git-status-test:shown-buffer) (buffers:live? (buffers:find "*git: repo*"))))
  (git-status-test:press! "C-x g")
  (git-status-test:press! "C-u q")
  (check-equal? #f (buffers:find "*git: repo*")))

(test "C-u C-u q kills every Git buffer of the repository, and no other"
  (git-status-test:sample! "other")
  (git-status:show (git:find-repository (git-status-test:path "other")))
  (layout:switch-to-buffer (files:visit (git-status-test:path "repo/a.py")))
  (git-status-test:press! "C-x g")
  (git-status-test:press! "$")
  (git-status-test:press! "C-x o")
  (layout:switch-to-buffer (buffers:find "*git: repo*"))
  (git-status-test:press! "C-u C-u q")
  (check-equal? '("*git: other*") (git-buffer-names)))
