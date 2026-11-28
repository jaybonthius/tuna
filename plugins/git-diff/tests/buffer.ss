(import (tuna) (test) (test-user) (options) (hooks) (buffers) (views) (layout) (layout-split) (editing) (ui) (git) (git-mode)
        (git-status) (git-apply) (git-diff) (git-status-test) (git-test repositories))

(define hooked '())

(hooks:add! git-diff:mode-hook (lambda () (set! hooked (cons 'diff hooked))))

(hooks:add! git-diff:revision-mode-hook (lambda () (set! hooked (cons 'revision hooked))))

(define repo (git-status-test:fresh! "repo"))

(define git! git-test/repositories:git!)

(define (press! keys) (git-status-test:press! keys))

(define (visible) (git-status-test:status))

(define (diff-buffer) (buffers:find "*git-diff: repo*"))

(define (buttons-of heading)
  (test-user:settle)
  (let ([h (find (lambda (e) (git-status-test:contains? (test-user:element-text e) heading))
                 (test-user:elements (git-status-test:drawn) "ui-section-heading"))])
    (if h (map test-user:element-text (test-user:elements h "git-apply-button")) 'no-heading)))

(test "git-diff:mode-hook runs in each diff buffer as its mode is set, git-diff:revision-mode-hook in each commit buffer"
  (press! "d u")
  (check-equal? '(diff) hooked)
  (git-diff:show-revision repo "HEAD" '())
  (check-equal? '(revision diff) (list-head hooked 2)))

(test "a file or hunk of an unstaged diff shows the stage and discard buttons, and a diffstat row too; a committed diff's, none"
  (layout:select! (layout:display-buffer (git-diff:show repo (git-diff:unstaged-spec) '())))
  (git-status-test:settle!)
  (check-equal? '("+" "⟲") (buttons-of "modified   a.py"))
  (check-equal? '("+" "⟲") (buttons-of "@@ -1,11 +1,11 @@"))
  (check-equal? '("+" "⟲") (buttons-of "a.py     | 4"))
  (layout:select! (layout:display-buffer (git-diff:show repo (git-diff:range-spec "HEAD~1..HEAD") '())))
  (git-status-test:settle!)
  (check-equal? '() (buttons-of "new file   long.txt")))

(test "g rebuilds the buffer from git; point stays on its section, and the history and arguments stay"
  (layout:select! (layout:display-buffer (git-diff:show repo (git-diff:unstaged-spec) '("-U1"))))
  (git-status-test:settle!)
  (git-status-test:go-to-section! '(file . "long.txt"))
  (git-test/repositories:write-file! "repo/a.py" "changed\n")
  (press! "g")
  (check-equal? '("modified   long.txt" ("-U1") #t)
                (list (git-status-test:point-line) (buffers:with-buffer (diff-buffer) (git:diff-arguments)) (and (member "back" (visible)) #t)))
  (check (member "+changed" (visible))))

(test "a change to the repository refreshes every diff buffer of it"
  (git-status-test:go-to-section! '(file . "a.py"))
  (press! "s")
  (check (not (member "modified   a.py" (visible))))
  (git! "repo" "reset" "-q" "--" "a.py")
  (git! "repo" "tag" "refresh-now")
  (git-mode:refresh-repository repo)
  (git-status-test:settle!)
  (check (member "modified   a.py" (visible))))

(test "D with -w and -- files reruns the diff with them when applied with g; -- limits it to the files"
  (git-status-test:answer! "long.txt")
  (press! "D - - - w g")
  (check-equal? '("-U1" "--ignore-all-space") (buffers:with-buffer (diff-buffer) (git:diff-arguments)))
  (check-equal? '("1 file changed, 2 insertions(+), 2 deletions(-)" "long.txt | 4") (list-head (visible) 2))
  (press! "D - w g"))

(test "the diff and commit buffers are two buffers, each reused by the next command of its kind"
  (let ([diff (diff-buffer)] [revision (buffers:find "*git-revision: repo*")])
    (press! "d s")
    (git-diff:show-revision repo "HEAD~1" '())
    (check (eq? diff (diff-buffer)))
    (check (eq? revision (buffers:find "*git-revision: repo*")))
    (check (not (eq? diff revision)))))

(test "a conflicted file in the unstaged diff draws its combined hunk with two prefix columns"
  (git-test/repositories:conflict! "conflict")
  (let ([c (git:find-repository (git-status-test:path "conflict"))])
    (layout:select! (layout:display-buffer (git-diff:show c (git-diff:unstaged-spec) '())))
    (git-status-test:settle!)
    (let ([after (member "unmerged   f.txt" (visible))])
      (check (and after (string=? "@@@" (substring (cadr after) 0 3)))))
    (check (member "++<<<<<<< HEAD" (visible)))))

(test "an entry of git-diff:sections adds its sections after the files"
  (let ([entry (lambda (spec) (list (ui:section '((type . note) (value . #f)) (git-diff:description spec))))])
    (hooks:add! git-diff:sections entry)
    (layout:select! (layout:display-buffer (git-diff:show repo (git-diff:staged-spec) '())))
    (git-status-test:settle!)
    (hooks:remove! git-diff:sections entry)
    (check-equal? "Staged changes" (list-ref (visible) (- (length (visible)) 2)))))
