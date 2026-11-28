(import (tuna) (test) (test-user) (test-runner) (options) (modes) (buffers) (document) (views) (layout) (layout-split) (editing) (files) (ui)
        (git) (git-mode) (git-status) (git-diff) (with-editor) (git-commit) (git-status-test) (git-test repositories))

(define repo (git-status-test:fresh! "repo"))

(define git! git-test/repositories:git!)

(define (message!) (git-status-test:wait-until-shown "COMMIT_EDITMSG"))

(define (diff-buffer) (buffers:find "*git-diff: repo*"))

(define (shown-diff)
  (let ([b (diff-buffer)])
    (and b (pair? (views:showing b)) (git-diff:description (git-diff:buffer-spec b)))))

(define (view-count) (length (layout:views)))

;; The diff is built in a task of its own once the message buffer opens,
;; and git still waits for the message, so this waits for the diff alone.
(define (diff-shown-as description)
  (test-runner:wait-until (lambda () (equal? description (shown-diff))))
  (test-user:settle)
  (shown-diff))

(define (cancel!) (git-status-test:press! "C-c C-k"))

(define (shown-buffers) (map (lambda (v) (and (views:buffer v) (buffers:name (views:buffer v)))) (layout:views)))

(test "c c with something staged shows the staged diff in another view, the message buffer staying selected, and says so; the views are as they were after"
  (git-status-test:take-said!)
  (let ([before (shown-buffers)])
    (test-user:press! "c c")
    (let ([m (message!)])
      (check-equal? "Staged changes" (diff-shown-as "Staged changes"))
      (check (eq? m (views:buffer (git-status-test:view))))
      (check (member "Diffing changes to be committed (C-g to abort diffing)" (git-status-test:take-said!)))
      (cancel!)
      (check-equal? before (shown-buffers)))))

(test "C-c C-d shows the diff again after its view was quit, and with it already shown says No alternative diff while committing"
  (test-user:press! "c c")
  (let ([m (message!)])
    (diff-shown-as "Staged changes")
    (let ([message-view (git-status-test:view)])
      (layout:select! (car (views:showing (diff-buffer))))
      (git-status-test:press-done! "q")
      (check-equal? #f (shown-diff))
      (layout:select! message-view)
      (git-status-test:press-done! "C-c C-d")
      (check-equal? "Staged changes" (shown-diff))
      (check (eq? m (views:buffer (git-status-test:view)))))
    (check-equal? '("No alternative diff while committing") (git-status-test:press-reporting-messages! "C-c C-d"))
    (cancel!)))

(test "C-c C-d is bound in message and diff buffers alone; with no commit in progress a diff buffer says so"
  (check-equal? '("C-c C-d is undefined") (git-status-test:press-reporting-messages! "C-c C-d"))
  (layout:select! (layout:display-buffer (git-diff:show repo (git-diff:unstaged-spec) '())))
  (git-status-test:settle!)
  (check-equal? '("No commit in progress") (git-status-test:press-reporting-messages! "C-c C-d"))
  (git-status-test:press! "q")
  (layout:switch-to-buffer (git-status-test:status-buffer)))

(test "c a shows the index against HEAD^, and C-c C-d turns it to the changes the amend adds and back"
  (test-user:press! "c a")
  (message!)
  (check-equal? "Changes from HEAD^ to index" (diff-shown-as "Changes from HEAD^ to index"))
  (git-status-test:press-done! "C-c C-d")
  (check-equal? "Staged changes" (shown-diff))
  (git-status-test:press-done! "C-c C-d")
  (check-equal? "Changes from HEAD^ to index" (shown-diff))
  (cancel!))

(test "c w shows HEAD^..HEAD"
  (test-user:press! "c w")
  (message!)
  (check-equal? "Changes in HEAD^..HEAD" (diff-shown-as "Changes in HEAD^..HEAD"))
  (cancel!))

(test "c c with --all shows HEAD against the working tree"
  (test-user:press! "c - a c")
  (message!)
  (check-equal? "Changes from HEAD to working tree" (diff-shown-as "Changes from HEAD to working tree"))
  (cancel!))

(test "the message keeps git's own diff below the scissors line, folded, and the diff view shows beside it; typing goes on while the diff is built"
  (test-user:press! "c c")
  (let ([m (message!)])
    (test-user:type! "Typed at once")
    (check (git-status-test:contains? (document:text (buffers:document m)) "Typed at once"))
    (check (git-status-test:contains? (document:text (buffers:document m)) "# ------------------------ >8 ------------------------"))
    (check (pair? (views:folds-at (git-status-test:view) (- (document:length (buffers:document m)) 2))))
    (check-equal? "Staged changes" (diff-shown-as "Staged changes"))
    (cancel!)))

(test "with git-commit:show-diff #f no diff shows, and C-c C-d still shows it"
  (options:set! git-commit:show-diff #f)
  (let ([before (shown-buffers)])
    (test-user:press! "c c")
    (message!)
    (test-user:settle)
    (check-equal? #f (shown-diff))
    (git-status-test:press-done! "C-c C-d")
    (check-equal? "Staged changes" (shown-diff))
    (cancel!))
  (options:unset! git-commit:show-diff))

(test "c c with nothing staged shows the unstaged diff while it asks, and closes it after the answer"
  (git! "repo" "reset" "-q")
  (git-mode:refresh-repository repo)
  (layout:switch-to-buffer (git-status-test:status-buffer))
  (for-each (lambda (v) (unless (eq? v (layout:selected-view)) (layout:delete-part! (layout:view-node v)))) (layout:views))
  (git-status-test:settle!)
  (let ([before (shown-buffers)] [seen #f])
    (options:set! ask:y-or-n-reader (lambda (q) (set! seen (list q (shown-diff))) #f))
    (git-status-test:press! "c c")
    (options:set! ask:y-or-n-reader (lambda (q) (error 'git-commit-test "no answer" q)))
    (check-equal? (list "Nothing staged.  Commit all uncommitted changes? " "Unstaged changes") seen)
    (check-equal? before (shown-buffers))))

(test "c c with --allow-empty and nothing staged shows HEAD against the working tree"
  (options:set! ask:y-or-n-reader (lambda (q) #t))
  (test-user:press! "c - e c")
  (message!)
  (check-equal? "Changes from HEAD to working tree" (diff-shown-as "Changes from HEAD to working tree"))
  (cancel!)
  (options:unset! ask:y-or-n-reader))
