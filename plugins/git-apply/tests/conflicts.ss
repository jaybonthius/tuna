(import (tuna) (test) (test-user) (buffers) (views) (layout) (layout-split) (editing) (files) (ui) (git) (git-mode) (git-status) (git-apply)
        (git-status-test) (git-test repositories))

(define git! git-test/repositories:git!)

(define repo
  (let ([write! (lambda (text) (git-test/repositories:write-file! "c/f.txt" text))])
    (git! "" "init" "-q" "-b" "main" "c")
    (write! "a\nb\nc\n")
    (git! "c" "add" "f.txt")
    (git! "c" "commit" "-qm" "base")
    (git! "c" "checkout" "-q" "-b" "other")
    (write! "a\nOTHER\nc\n")
    (git! "c" "commit" "-qam" "other")
    (git! "c" "checkout" "-q" "main")
    (write! "a\nMAIN\nc\n")
    (git! "c" "commit" "-qam" "main")
    (git-test/repositories:run! "c" "sh" "-c" "git merge -q other || true")
    (git:find-repository (git-status-test:path "c"))))

(git-status:show repo)
(git-status-test:settle!)

(define combined '(hunk . "@@@ -1,3 -1,3 +1,7 @@@"))

(define (refused who message keys) (check-equal? (list (list who message)) (git-status-test:press-reporting! keys)))

(test "a conflicted file shows as unmerged under both lists, its combined hunk under Unstaged changes with two prefix columns, and no Merging section"
  (ui:show-section! (git-status-test:view) (git-status-test:section '(file . "f.txt") '(unstaged . #f)))
  (check-equal? '("Head:     main main" "Unstaged changes (1)" "unmerged   f.txt" "@@@ -1,3 -1,3 +1,7 @@@" "  a" "++<<<<<<< HEAD" " +MAIN"
                  "++=======" "+ OTHER" "++>>>>>>> other" "  c" "Staged changes (1)" "unmerged   f.txt" "Recent commits…")
                (git-status-test:status))
  (check (not (exists (lambda (s) (eq? 'merging (ui:section-type s))) (ui:section-children (git-status-test:section '(unstaged . #f)))))))

(test "s and k on the combined hunk, or s on lines of it, raise Cannot un-/stage resolution hunks"
  (git-status-test:go-to-section! combined '(file . "f.txt") '(unstaged . #f))
  (refused 'diff:hunks-patch "Cannot un-/stage resolution hunks.  Stage the whole file" "s")
  (refused 'diff:reverse-hunks-patch "Cannot un-/stage resolution hunks.  Stage the whole file" "k")
  (git-status-test:go-to-in! "++<<<<<<< HEAD" '(file . "f.txt") '(unstaged . #f))
  (views:set-mark! (git-status-test:view) (views:point (git-status-test:view)))
  (test-user:press! "C-e")
  (refused 'diff:lines-patch "Cannot un-/stage resolution hunks.  Stage the whole file" "s")
  (views:set-mark! (git-status-test:view) #f))

(test "RET on the conflicted file visits it"
  (git-status-test:go-to-section! '(file . "f.txt") '(unstaged . #f))
  (git-status-test:press! "RET")
  (check-equal? "f.txt" (git-status-test:shown-buffer))
  (layout:switch-to-buffer (git-status-test:status-buffer)))

(test "k on the conflicted file, and u on it under Staged changes, raise until conflicts can be resolved"
  (git-status-test:go-to-section! '(file . "f.txt") '(unstaged . #f))
  (refused 'git-apply:discard "Discarding a conflict waits for conflict resolution" "k")
  (git-status-test:go-to-section! '(file . "f.txt") '(staged . #f))
  (refused 'git-apply:unstage "Unstaging a conflict waits for conflict resolution" "u"))

(test "s on the conflicted file stages it as it stands"
  (git-status-test:go-to-section! '(file . "f.txt") '(unstaged . #f))
  (git-status-test:press! "s")
  (check-equal? "M  f.txt\n" (git-status-test:short "c"))
  (check-equal? '("Head:     main main" "Staged changes (1)" "modified   f.txt…" "Recent commits…") (git-status-test:status)))
