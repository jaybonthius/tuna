(import (tuna) (test) (test-user) (views) (layout) (layout-split) (editing) (ui) (git) (git-mode) (git-status) (git-apply)
        (git-status-test))

(define repo (git-status-test:fresh! "buttons"))

(ui:show-section! (git-status-test:view) (git-status-test:section '(untracked . #f)))

(test "a file, hunk and list heading carry their buttons, drawn after the heading and no text: + or − and ⟲"
  (check-equal? '("+" "⟲") (map test-user:element-text (map (lambda (t) (git-status-test:row-button "unstaged" "a.py" t)) '("Stage" "Discard"))))
  (check-equal? '("−" "⟲") (map test-user:element-text (map (lambda (t) (git-status-test:row-button "staged" "b.txt" t)) '("Unstage" "Discard"))))
  (check-equal? '("+" "⟲") (map test-user:element-text (map (lambda (t) (git-status-test:row-button "untracked" "Untracked" t)) '("Stage" "Discard"))))
  (check-equal? #f (git-status-test:row-button "unstaged" "a.py" "Unstage"))
  (check (not (exists (lambda (l) (git-status-test:contains? l "⟲")) (git-status-test:status)))))

(test "a row's buttons stage, unstage and discard that row whatever point is, and point and the selected view stay"
  (git-status-test:press! "M-<")
  (let ([before (views:point (git-status-test:view))] [v (git-status-test:view)])
    (git-status-test:click-button! "unstaged" "a.py" "Stage")
    (check-equal? '("M  a.py\n" #t #t) (list (git-status-test:short "buttons" "a.py") (= before (views:point v)) (eq? v (git-status-test:view))))
    (git-status-test:click-button! "staged" "a.py" "Unstage")
    (check-equal? " M a.py\n" (git-status-test:short "buttons" "a.py"))
    (git-status-test:answer! #t)
    (git-status-test:click-button! "unstaged" "a.py" "Discard")
    (check-equal? '(("Discard unstaged changes in \"a.py\"? ") "" #t)
                  (list (git-status-test:take-asked!) (git-status-test:short "buttons" "a.py") (= before (views:point v))))))

(test "a hunk's button stages the hunk, and a list's button the list"
  (ui:show-section! (git-status-test:view) (git-status-test:section '(file . "long.txt") '(unstaged . #f)))
  (git-status-test:click-button! "unstaged" "@@ -1,5 +1,5 @@" "Stage")
  (check-equal? " long.txt | 2 +-\n 1 file changed, 1 insertion(+), 1 deletion(-)\n"
                (git-status-test:git-out "buttons" "diff" "--cached" "--stat" "long.txt"))
  (git-status-test:answer! #t)
  (git-status-test:click-button! "unstaged" "Unstaged changes" "Stage")
  (check-equal? '("Stage all changes? ") (git-status-test:take-asked!))
  (check-equal? "M  b.txt\nD  gone.txt\nM  long.txt\n?? new.txt\n" (git-status-test:short "buttons")))

