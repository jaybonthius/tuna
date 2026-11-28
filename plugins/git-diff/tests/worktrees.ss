(import (tuna) (test) (test-user) (buffers) (views) (layout) (layout-split) (editing) (ui) (git) (git-mode)
        (git-status) (git-diff) (git-status-test) (git-test repositories))

(define repo (git-status-test:fresh! "repo"))

(define status-view (git-status-test:view))

(git-test/repositories:git! "repo" "worktree" "add" "-q" "../wt")

(define other (git:find-repository (git-status-test:path "wt")))

(define second (git:commit-name (car (git:commits repo "HEAD~1" 1))))

(define scrolled '())

(define (note next . arguments)
  (set! scrolled (cons (buffers:name (views:buffer (views:current))) scrolled))
  (apply next arguments))

(advice-add! views:scroll-up note)

(test "SPC on a commit shows it in this repository's commit buffer, though another worktree's commit buffer shows the same commit on screen"
  (layout:display-buffer (git-diff:show-revision other second '()))
  (layout:select! status-view)
  (git-status-test:settle!)
  (check (pair? (views:showing (buffers:find "*git-revision: wt*"))))
  (git-status-test:go-to-section! (cons 'commit second) '(unpushed . "@{upstream}"))
  (git-status-test:press! "SPC")
  (let ([mine (buffers:find "*git-revision: repo*")])
    (check-equal? '() scrolled)
    (check (and mine (pair? (views:showing mine))))
    (check (eq? status-view (git-status-test:view)))))
