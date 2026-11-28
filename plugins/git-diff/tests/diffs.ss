(import (tuna) (test) (test-user) (options) (modes) (buffers) (views) (layout) (layout-split) (editing) (ui) (git) (git-mode)
        (git-status) (git-apply) (git-diff) (diff-sections) (transient-test) (git-status-test) (git-test repositories))

(define repo (git-status-test:fresh! "repo"))

(define status-view (git-status-test:view))

(define (press! keys) (git-status-test:press! keys))

(define (shown) (git-status-test:shown-buffer))

(define (visible) (git-status-test:status))

(define (first-lines n) (list-head (visible) n))

(define (segments) (map test-user:element-text (test-user:elements (test-user:screen) "status-line-segment")))

(define (back-to-status!)
  (layout:select! status-view)
  (layout:switch-to-buffer (git-status-test:status-buffer))
  (git-status-test:settle!))

(define (refused who message keys) (check-equal? (list (list who message)) (git-status-test:press-reporting! keys)))

(test "d shows the diff menu: its argument groups, then its actions, its arguments starting from git:diff-arguments"
  (press! "d")
  (check-equal? '("Diff"
                  ("Limit arguments" ("- -" "Limit to files") ("- i" "Ignore submodules") ("- b" "Ignore whitespace changes")
                   ("- w" "Ignore all whitespace"))
                  ("Context arguments" ("- U" "Context lines") ("- W" "Show surrounding functions"))
                  ("Tune arguments" ("- A" "Diff algorithm") ("- M" "Detect renames") ("- C" "Detect copies") ("- T" "Use textconv"))
                  ("Actions" ("d" "Dwim") ("r" "Diff range") ("u" "Diff unstaged") ("s" "Diff staged") ("w" "Diff worktree") ("c" "Show commit")))
                (map (lambda (g) (if (pair? g) (cons (car g) (map (lambda (e) (if (pair? e) (list-head e 2) e)) (cdr g))) g))
                     (transient-test:menu)))
  (press! "C-g"))

(test "d u shows the unstaged changes in *git-diff: NAME*, in another view it selects: the diffstat, then the files, expanded"
  (press! "d u")
  (check-equal? "*git-diff: repo*" (shown))
  (check (not (eq? status-view (git-status-test:view))))
  (check (eq? (git-status-test:status-buffer) (views:buffer status-view)))
  (check-equal? '("4 files changed, 5 insertions(+), 6 deletions(-)" "a.py     | 4" "b.txt    | 2" "gone.txt | 1" "long.txt | 4"
                  "modified   a.py" "@@ -1,11 +1,11 @@")
                (first-lines 7))
  (check (member "Unstaged changes" (segments)))
  (check-equal? '(git-diff:mode git-mode:mode ui:section-mode modes:special) (modes:ancestry (modes:major-mode (views:buffer (git-status-test:view))))))

(test "a second diff command shows its diff in the same buffer; C-c C-b and C-c C-f go back and forward, and say when there is nowhere to go"
  (press! "d s")
  (check-equal? '("*git-diff: repo*" "1 file changed, 1 insertion(+), 1 deletion(-)" "b.txt | 2") (cons (shown) (first-lines 2)))
  (check (member "Staged changes" (segments)))
  (check (member "back" (visible)))
  (press! "C-c C-b")
  (check-equal? "4 files changed, 5 insertions(+), 6 deletions(-)" (car (visible)))
  (refused 'git-diff:back "No previous diff" "C-c C-b")
  (press! "C-c C-f")
  (check-equal? "1 file changed, 1 insertion(+), 1 deletion(-)" (car (visible)))
  (refused 'git-diff:forward "No next diff" "C-c C-f"))

(test "d w shows HEAD against the working tree, and C-u d s the index against a revision read"
  (press! "d w")
  (check (member "Changes from HEAD to working tree" (segments)))
  (check (member "@@ -1,8 +1,8 @@" (visible)))
  (git-status-test:answer! "HEAD~1")
  (press! "d C-u s")
  (check-equal? '("Diff index and commit: ") (git-status-test:take-asked!))
  (check (member "Changes from HEAD~1 to index" (segments))))

(test "d d on Unstaged changes or a file in it shows the unstaged changes; on Staged changes the staged ones"
  (back-to-status!)
  (git-status-test:go-to-section! '(file . "a.py") '(unstaged . #f))
  (press! "d d")
  (check (member "Unstaged changes" (segments)))
  (back-to-status!)
  (git-status-test:go-to-section! '(staged . #f))
  (press! "d d")
  (check (member "Staged changes" (segments))))

(test "d d on a commit row shows C^..C; on Unmerged into the upstream, its three-dot range"
  (back-to-status!)
  (git-status-test:go-to-in! "Second commit" '(unpushed . "@{upstream}"))
  (press! "d d")
  (let ([name (git:commit-short-name (car (git:commits repo "HEAD~1" 1)))])
    (check (exists (lambda (s) (git-status-test:contains? s "^..")) (segments))))
  (back-to-status!)
  (git-status-test:go-to-section! '(unpushed . "@{upstream}"))
  (press! "d d")
  (check (member "Changes in @{upstream}...HEAD" (segments))))

(test "d d where nothing applies reads a range; a range git refuses says git's message and shows nothing"
  (back-to-status!)
  (press! "M-<")
  (git-status-test:answer! "no-such-branch")
  (let ([messages (git-status-test:press-reporting! "d d")])
    (check-equal? '("Diff for range: ") (git-status-test:take-asked!))
    (check (pair? messages)))
  (check-equal? "*git: repo*" (shown)))

(test "d s with nothing staged shows No changes, and says so"
  (git-test/repositories:git! "repo" "reset" "-q")
  (git-mode:refresh-repository repo)
  (back-to-status!)
  (git-status-test:take-said!)
  (press! "d s")
  (check-equal? "No changes" (car (visible)))
  (check (member "No changes" (git-status-test:take-said!)))
  (git-test/repositories:git! "repo" "add" "b.txt")
  (git-mode:refresh-repository repo))

(test "RET on Unstaged changes shows its diff, and on a commit row its commit buffer"
  (back-to-status!)
  (git-status-test:go-to-section! '(unstaged . #f))
  (press! "RET")
  (check (member "Unstaged changes" (segments)))
  (back-to-status!)
  (git-status-test:go-to-in! "Second commit" '(unpushed . "@{upstream}"))
  (press! "RET")
  (check-equal? "*git-revision: repo*" (shown)))

(test "the commit buffer: refs and full hash, author and committer with git's dates, parents, related refs, message, diffstat and diff"
  (let ([lines (visible)] [hash (git:commit-name (car (git:commits repo "HEAD~1" 1)))])
    (check-equal? hash (car lines))
    (check-equal? '("Author:     Tuna <tuna@example.org>" "AuthorDate: ")
                  (list (cadr lines) (substring (caddr lines) 0 12)))
    (check (member "Commit:     Tuna <tuna@example.org>" lines))
    (check (exists (lambda (l) (git-status-test:contains? l "Parent:     ")) lines))
    (check (exists (lambda (l) (git-status-test:contains? l "Contained:  main")) lines))
    (check (member "Second commit" lines))
    (check (member "1 file changed, 1 insertion(+)" lines))
    (check (member "modified   a.py" lines))
    (check-equal? '(git-diff:revision-mode git-diff:mode git-mode:mode ui:section-mode modes:special)
                  (modes:ancestry (modes:major-mode (views:buffer (git-status-test:view)))))))

(test "RET on a Parent row shows the parent in the same buffer, keeping the child on its history"
  (git-status-test:go-to! "Parent:")
  (press! "RET")
  (check (member "First commit" (visible)))
  (press! "C-c C-b")
  (check (member "Second commit" (visible))))

(test "d c on a name that is no commit says it cannot be dereferenced"
  (git-status-test:answer! "nothing-here")
  (refused 'git-diff:show-commit "nothing-here cannot be dereferenced as a commit" "C-u d c"))

(test "j in a diff buffer goes to the diffstat, from a row to its file, from a file to its row; RET on a row visits its file"
  (back-to-status!)
  (press! "d u")
  (git-status-test:go-to-section! '(file . "long.txt"))
  (press! "j")
  (check-equal? "long.txt | 4" (git-status-test:point-line))
  (press! "j")
  (check-equal? "modified   long.txt" (git-status-test:point-line))
  (git-status-test:go-to! "a.py     | 4")
  (press! "j")
  (check-equal? "modified   a.py" (git-status-test:point-line))
  (git-status-test:go-to! "a.py     | 4")
  (press! "RET")
  (check-equal? "a.py" (shown))
  (layout:switch-to-buffer (buffers:find "*git-diff: repo*")))

(test "+, - and 0 change the context of every diff of the buffer, locally"
  (press! "+")
  (check-equal? '("-U4") (buffers:with-buffer (views:buffer (git-status-test:view)) (git:diff-arguments)))
  (check (member "@@ -1,6 +1,6 @@" (visible)))
  (press! "C-u 2 +")
  (check-equal? '("-U6") (buffers:with-buffer (views:buffer (git-status-test:view)) (git:diff-arguments)))
  (press! "-")
  (check-equal? '("-U5") (buffers:with-buffer (views:buffer (git-status-test:view)) (git:diff-arguments)))
  (press! "0")
  (check-equal? '() (buffers:with-buffer (views:buffer (git-status-test:view)) (git:diff-arguments)))
  (check-equal? '() (git:diff-arguments)))

(test "+ in the status buffer changes its diffs' context"
  (back-to-status!)
  (press! "+")
  (check-equal? '("-U4") (buffers:with-buffer (git-status-test:status-buffer) (git:diff-arguments)))
  (press! "0"))

(test "D S hides the diffstat and shows it again; D r and D f switch and flip a range, and refuse a diff with none"
  (press! "d u")
  (press! "D S")
  (check-equal? "modified   a.py" (car (visible)))
  (press! "D S")
  (refused 'git-diff:switch-range-type "No range to change" "D r")
  (git-status-test:answer! "HEAD~1..HEAD")
  (press! "d r")
  (press! "D r")
  (check (member "Changes in HEAD~1...HEAD" (segments)))
  (press! "D f")
  (check (member "Changes in HEAD...HEAD~1" (segments))))

(test "D L sets the buffer's layout"
  (press! "d u")
  (options:set! ask:choice-reader (lambda (q choices) (cdr (assoc "split" choices))))
  (press! "D L")
  (options:unset! ask:choice-reader)
  (check-equal? 'split (buffers:with-buffer (views:buffer (git-status-test:view)) (diff-sections:layout))))

(test "D with -T makes the diff with textconv, which s refuses to apply"
  (press! "D - T g")
  (git-status-test:go-to-section! '(file . "a.py"))
  (refused 'git-apply:stage "This diff was made with textconv and cannot be applied" "s")
  (press! "D - T g"))

(test "q quits the diff's view, showing what the view showed before, and the status buffer's view stays"
  (press! "q")
  (check-equal? '("a.py" #t) (list (shown) (eq? (git-status-test:status-buffer) (views:buffer status-view))))
  (layout:switch-to-buffer (buffers:find "*git-revision: repo*"))
  (press! "C-u q")
  (check-equal? #f (buffers:find "*git-revision: repo*")))
