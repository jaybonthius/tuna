(import (tuna) (test) (test-user) (options) (tables) (buffers) (views) (layout) (layout-split) (editing) (ui) (git) (git-mode)
        (git-status) (git-diff) (git-status-test) (git-test repositories))

(define repo (git-status-test:fresh! "repo"))

(define git! git-test/repositories:git!)

(define status-view (git-status-test:view))

(define (press! keys) (git-status-test:press! keys))

(define (segments) (map test-user:element-text (test-user:elements (test-user:screen) "status-line-segment")))

(define (back-to-status!)
  (layout:select! status-view)
  (layout:switch-to-buffer (git-status-test:status-buffer))
  (git-status-test:settle!))

(define (diff-spec) (git-diff:buffer-spec (buffers:find "*git-diff: repo*")))

(test "d d on a stash row, which has no diff target until stashes have a plugin, reads a range"
  (git-test/repositories:write-file! "repo/s.txt" "s\n")
  (git! "repo" "add" "s.txt")
  (git! "repo" "stash" "push" "-q" "--" "s.txt")
  (git-mode:refresh-repository repo)
  (git-status-test:settle!)
  (ui:show-section! status-view (git-status-test:section '(stashes . #f)))
  (git-status-test:go-to-section! '(stash . "stash@{0}") '(stashes . #f))
  (git-status-test:answer! "HEAD~1")
  (press! "d d")
  (check-equal? '("Diff for range: ") (git-status-test:take-asked!))
  (check (member "Changes from HEAD~1 to working tree" (segments))))

(test "d d with the region over commit rows shows LAST..FIRST of their commits and ends the region"
  (back-to-status!)
  (ui:show-section! status-view (git-status-test:section '(unpushed . "@{upstream}")))
  (let ([first (git:commit-name (car (git:commits repo "HEAD" 1)))] [last (git:commit-name (car (git:commits repo "HEAD~1" 1)))])
    (git-status-test:go-to-section! (cons 'commit first) '(unpushed . "@{upstream}"))
    (views:set-mark! status-view (views:point status-view))
    (git-status-test:go-to-section! (cons 'commit last) '(unpushed . "@{upstream}"))
    (press! "d d")
    (check (member (string-append "Changes in " last ".." first) (segments)))
    (check-equal? #f (views:mark status-view))))

(test "d d in a diff buffer shows its diff again; in a commit buffer, its commit"
  (press! "d u")
  (press! "d d")
  (check (member "Unstaged changes" (segments)))
  (check (eq? 'unstaged (and (git-diff:spec=? (diff-spec) (git-diff:unstaged-spec)) 'unstaged)))
  (back-to-status!)
  (git-status-test:go-to-in! "Second commit" '(unpushed . "@{upstream}"))
  (press! "RET")
  (let ([b (views:buffer (git-status-test:view))])
    (press! "d d")
    (check-equal? "*git-revision: repo*" (git-status-test:shown-buffer))
    (check (eq? b (views:buffer (git-status-test:view))))))

(test "an entry of git-diff:dwim-targets gives d d on a section type of its own"
  (back-to-status!)
  (let ([asked '()])
    (tables:set! git-diff:dwim-targets 'stash
      (lambda (section view)
        (set! asked (cons (ui:section-value section) asked))
        (git-diff:show repo (git-diff:range-spec (string-append (ui:section-value section) "^.." (ui:section-value section))) '())
        #t))
    (git-status-test:go-to-section! '(stash . "stash@{0}") '(stashes . #f))
    (press! "d d")
    (tables:remove! git-diff:dwim-targets 'stash)
    (check-equal? '("stash@{0}") asked)
    (check (git-diff:spec=? (git-diff:range-spec "stash@{0}^..stash@{0}") (diff-spec)))))
