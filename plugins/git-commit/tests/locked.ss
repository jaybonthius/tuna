(import (tuna) (test) (test-user) (test-runner) (modes) (buffers) (views) (layout) (layout-split) (editing) (ui) (git) (git-mode)
        (git-status) (git-diff) (with-editor) (git-commit) (git-status-test) (git-test repositories))

(define repo (git-status-test:fresh! "repo"))

(define status-view (git-status-test:view))

(define (message!) (git-status-test:wait-until-shown "COMMIT_EDITMSG"))

(define (unlocked) (git-mode:unlocked-buffer repo git-diff:mode))

(define (description-of b) (and b (git-diff:description (git-diff:buffer-spec b))))

(define (shown-as description)
  (test-runner:wait-until (lambda () (let ([b (unlocked)]) (and b (pair? (views:showing b)) (equal? description (description-of b))))))
  (test-user:settle)
  (description-of (unlocked)))

(define (shown-buffers) (map (lambda (v) (and (views:buffer v) (buffers:name (views:buffer v)))) (layout:views)))

(define (cancel!) (git-status-test:press! "C-c C-k"))

(define locked
  (let ([b (git-diff:show repo (git-diff:range-spec "HEAD~1..HEAD") '())])
    (layout:select! (layout:display-buffer b))
    (git-status-test:settle!)
    (git-status-test:press! "D b")
    (layout:select! status-view)
    (git-status-test:settle!)
    b))

(test "with a locked diff buffer on screen, c c shows the commit's diff in a view of its own, and the views are as they were after"
  (check (and (pair? (views:showing locked)) (buffers:with-buffer locked (git-mode:locked?))))
  (let ([before (shown-buffers)])
    (test-user:press! "c c")
    (message!)
    (check-equal? "Staged changes" (shown-as "Staged changes"))
    (cancel!)
    (check-equal? before (shown-buffers))))

(test "while amending, C-c C-d toggles the commit's diff even when a locked diff buffer on screen is the newest"
  (test-user:press! "c a")
  (let ([m (message!)])
    (check-equal? "Changes from HEAD^ to index" (shown-as "Changes from HEAD^ to index"))
    (let ([message-view (git-status-test:view)])
      (git-status-test:press-done! "C-x 2")
      (let ([other (find (lambda (v) (and (eq? m (views:buffer v)) (not (eq? v message-view)))) (layout:views))])
        (layout:select! other)
        (layout:switch-to-buffer locked)
        (layout:select! message-view)
        (test-user:settle)
        (check (eq? locked (car (filter (lambda (b) (eq? (modes:major-mode b) git-diff:mode)) (buffers:all)))))
        (git-status-test:press-done! "C-c C-d")
        (check-equal? "Staged changes" (description-of (unlocked)))))
    (cancel!)))
