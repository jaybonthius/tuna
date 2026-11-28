(import (tuna) (test) (test-user) (hooks) (buffers) (views) (layout) (layout-split) (editing) (ui) (git) (git-mode)
        (git-status) (git-apply) (git-diff) (git-status-test) (git-test repositories))

(define repo (git-status-test:fresh! "repo"))

(define git! git-test/repositories:git!)

(define status-view (git-status-test:view))

(define rebuilt 0)

(hooks:add! git-diff:sections (lambda (spec) (set! rebuilt (+ rebuilt 1)) '()))

(define refreshed 0)

(hooks:add! git-mode:after-refresh (lambda (repository) (set! refreshed (+ refreshed 1))))

(define (back-to-status!)
  (layout:select! status-view)
  (layout:switch-to-buffer (git-status-test:status-buffer))
  (git-status-test:settle!))

(test "g in the status buffer refreshes it and no diff buffer; g in a diff buffer refreshes that one"
  (git! "repo" "branch" "topic" "HEAD~1")
  (git-status-test:answer! "topic")
  (git-status-test:press! "d r")
  (back-to-status!)
  (set! rebuilt 0)
  (set! refreshed 0)
  (git-status-test:press! "g")
  (check-equal? 0 rebuilt)
  (check-equal? 1 refreshed)
  (layout:select! (car (views:showing (buffers:find "*git-diff: repo*"))))
  (git-status-test:press! "g")
  (check-equal? 1 rebuilt))

(test "a diff buffer whose diff git now refuses does not stop the repository's refresh: staging works, the status buffer and after-refresh follow, and the failure is reported"
  (git! "repo" "branch" "-D" "topic")
  (back-to-status!)
  (git-status-test:go-to-section! '(file . "a.py") '(unstaged . #f))
  (set! refreshed 0)
  (let ([reported (git-status-test:press-reporting-messages! "s")])
    (check-equal? "M  a.py\n" (git-status-test:short "repo" "a.py"))
    (check (git-status-test:section '(file . "a.py") '(staged . #f)))
    (check (> refreshed 0))
    (check (exists (lambda (m) (git-status-test:contains? m "topic")) reported))))
