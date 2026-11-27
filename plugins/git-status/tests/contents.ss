(import (tuna) (test) (test-user) (hooks) (options) (buffers) (document) (views) (layout) (layout-split) (editing) (files) (ui)
        (git) (git-mode) (git-status) (git-status-test) (git-test repositories))

(define git! git-test/repositories:git!)

(define (lines-starting prefix)
  (filter (lambda (l) (and (>= (string-length l) (string-length prefix)) (string=? prefix (substring l 0 (string-length prefix)))))
          (git-status-test:status)))

(define (short-name repo revision) (substring (git-status-test:git-out (git:repository-name repo) "rev-parse" "--short" revision) 0 7))

(define (faces-of class)
  (map (lambda (e) (list (test-user:element-attribute e "data-face") (test-user:element-text e)))
       (filter (lambda (e) (test-user:element-attribute e "data-face")) (test-user:elements-with (git-status-test:drawn) "data-face"))))

(define (face-texts face)
  (map cadr (filter (lambda (f) (equal? face (car f))) (faces-of #f))))

(test "with a push-remote whose branch differs from the upstream, both sides' commits not pushed and not pulled show, in Magit's order; those of the push branch start hidden"
  (let ([repo (git-status-test:sample! "repo")])
    (git! "" "init" "-q" "--bare" "-b" "main" "fork.git")
    (git! "repo" "remote" "add" "fork" "../fork.git")
    (git! "repo" "push" "-q" "fork" "main~1:refs/heads/main")
    (git! "repo" "config" "branch.main.pushRemote" "fork")
    (for-each
      (lambda (origin clone file subject)
        (git! "" "clone" "-q" origin clone)
        (git-test/repositories:write-file! (string-append clone "/" file) "x\n")
        (git! clone "add" file)
        (git! clone "commit" "-qm" subject)
        (git! clone "push" "-q"))
      '("origin-repo.git" "fork.git") '("o" "f") '("o.txt" "f.txt") '("Origin commit" "Fork commit"))
    (git! "repo" "fetch" "-q" "origin")
    (git! "repo" "fetch" "-q" "fork")
    (layout:switch-to-buffer (files:visit (git-status-test:path "repo/a.py")))
    (git-status-test:press! "C-x g")
    (check-equal? (list "Head:     main Second commit" "Merge:    origin/main Origin commit" "Push:     fork/main Fork commit"
                        "Untracked files (1)…" "Unstaged changes (3)" "modified   a.py…" "modified   b.txt…" "deleted    gone.txt…"
                        "Staged changes (1)" "modified   b.txt…" "Unpushed to fork/main (1)…" "Unmerged into origin/main (1)"
                        (string-append (short-name repo "HEAD") " main Second commit") "Unpulled from fork/main (1)…"
                        "Unpulled from origin/main (1)…")
                  (git-status-test:status))))

(test "the Merge line's commits to push and to pull are drawn after it, ↑N and ↓N in their faces, and are no text"
  (check-equal? '("↑1") (face-texts "git-status.ahead"))
  (check-equal? '("↓1") (face-texts "git-status.behind"))
  (check (not (exists (lambda (l) (git-status-test:contains? l "↑")) (git-status-test:status)))))

(test "names are drawn in the faces of local and remote branches, and hashes in git-status.hash"
  (check (member "main" (face-texts "git-status.branch-local")))
  (check (member "origin/main" (face-texts "git-status.branch-remote")))
  (check (member "fork/main" (face-texts "git-status.branch-remote")))
  (check (member (short-name (git:find-repository (git-status-test:path "repo")) "HEAD") (face-texts "git-status.hash"))))

(define rows (git-status-test:sample! "rows"))

(test "a file row is its status word padded to 11 characters, then its path"
  (git! "rows" "mv" "b.txt" "c.txt")
  (git! "rows" "add" "new.txt")
  (delete-file (git-status-test:path "rows/a.py"))
  (git-status:show rows)
  (git-status-test:settle!)
  (check-equal? '("deleted    a.py…" "modified   c.txt…" "deleted    gone.txt…" "renamed    b.txt -> c.txt…" "new file   new.txt…")
                (filter (lambda (l) (memv (string-ref l 0) '(#\d #\m #\r #\n))) (list-tail (git-status-test:status) 2))))

(test "a tracked file replaced by a symbolic link shows as a deletion and an addition, and s on either stages the type change"
  (git! "rows" "reset" "-q")
  (git! "rows" "checkout" "-q" "--" ".")
  (delete-file (git-status-test:path "rows/new.txt"))
  (git-test/repositories:write-file! "rows/swap.txt" "x\n")
  (git! "rows" "add" "swap.txt")
  (git! "rows" "commit" "-qm" "swap")
  (delete-file (git-status-test:path "rows/swap.txt"))
  (git-test/repositories:run! "rows" "ln" "-s" "a.py" "swap.txt")
  (git-mode:refresh-repository rows)
  (check-equal? '("Unstaged changes (2)" "deleted    swap.txt…" "new file   swap.txt…")
                (list-head (member "Unstaged changes (2)" (git-status-test:status)) 3))
  (git-status-test:go-to! "new file   swap.txt")
  (git-status-test:press! "s")
  (check-equal? "T  swap.txt\n" (git-status-test:short "rows" "swap.txt")))

(test "while the repository's last command failed, the first line is the error header, in its faces, until a command succeeds"
  (git-mode:start rows '("fetch" "nowhere") (lambda (c) (void)))
  (git-status-test:settle!)
  (check-equal? '("Git error: Could not read from remote repository. [Type $ for details]") (git-status-test:take-said!))
  (check-equal? "GitError! Could not read from remote repository.  [Type $ for details]" (car (git-status-test:status)))
  (check-equal? '("GitError! ") (face-texts "git-status.header"))
  (git:run rows '("tag" "v1"))
  (git-status-test:settle!)
  (check-equal? '("Head:     main swap" "Merge:    origin/main First commit" "Tag:      v1") (list-head (git-status-test:status) 3)))

(test "the Tag line names the nearest tag, in git-status.tag, and the commits since it"
  (git! "rows" "commit" "-qm" "after")
  (git-mode:refresh-repository rows)
  (check-equal? '("Head:     main after" "Merge:    origin/main First commit" "Tag:      v1 (1)") (list-head (git-status-test:status) 3))
  (check-equal? '("v1") (face-texts "git-status.tag")))

(test "with no upstream the commits are Recent commits, git-status:commit-count of them"
  (git! "rows" "branch" "--unset-upstream")
  (options:set! git-status:commit-count 2)
  (git-mode:refresh-repository rows)
  (ui:show-section! (git-status-test:view) (git-status-test:section '(recent . #f)))
  (check-equal? '("Recent commits" "main after" "tag: v1 swap")
    (map (lambda (l) (if (string=? l "Recent commits") l (substring l 8 (string-length l))))
         (list-head (member "Recent commits" (git-status-test:status)) 3)))
  (check-equal? 2 (length (ui:section-children (git-status-test:section '(recent . #f)))))
  (options:unset! git-status:commit-count))

(define repo (git-status-test:fresh! "fresh"))

(define (untracked) (map ui:section-value (filter (lambda (s) (eq? 'file (ui:section-type s))) (ui:section-children (git-status-test:section '(untracked . #f))))))

(test "past git-status:file-list-limit untracked files, the list ends in how many are not listed"
  (options:set! git-status:file-list-limit 2)
  (git-test/repositories:write-file! "fresh/u1.txt" "1\n")
  (git-test/repositories:write-file! "fresh/u2.txt" "2\n")
  (git-mode:refresh-repository repo)
  (ui:show-section! (git-status-test:view) (git-status-test:section '(untracked . #f)))
  (check-equal? '("Untracked files (3)" "new.txt" "u1.txt" "1 files not listed") (list-head (list-tail (git-status-test:status) 2) 4))
  (options:unset! git-status:file-list-limit))

(test "git-status:untracked-files lists by folder, every file or none; #f follows status.showUntrackedFiles"
  (git-test/repositories:write-file! "fresh/folder/x.txt" "x\n")
  (git-test/repositories:write-file! "fresh/folder/y.txt" "y\n")
  (git-mode:refresh-repository repo)
  (check-equal? '("folder/" "new.txt" "u1.txt" "u2.txt") (untracked))
  (options:set! git-status:untracked-files (git:untracked-listing all))
  (git-mode:refresh-repository repo)
  (check-equal? '("folder/x.txt" "folder/y.txt" "new.txt" "u1.txt" "u2.txt") (untracked))
  (options:set! git-status:untracked-files (git:untracked-listing no))
  (git-mode:refresh-repository repo)
  (check-equal? #f (git-status-test:section '(untracked . #f)))
  (options:unset! git-status:untracked-files)
  (git! "fresh" "config" "status.showUntrackedFiles" "no")
  (git-mode:refresh-repository repo)
  (check-equal? #f (git-status-test:section '(untracked . #f)))
  (git! "fresh" "config" "--unset" "status.showUntrackedFiles"))

(test "advice on git:untracked leaves paths out of the list"
  (let ([without-folder (lambda (original repository listing)
                          (filter (lambda (p) (not (string=? (utf8->string p) "folder/"))) (original repository listing)))])
    (advice-add! git:untracked without-folder)
    (git-mode:refresh-repository repo)
    (advice-remove! git:untracked without-folder)
    (check-equal? '("new.txt" "u1.txt" "u2.txt") (untracked))))

(test "stashes are listed, hidden at first, each its name in git-status.stash and its summary"
  (git-test/repositories:write-file! "fresh/s.txt" "s\n")
  (git! "fresh" "add" "s.txt")
  (git! "fresh" "stash" "push" "-q" "--" "s.txt")
  (git-mode:refresh-repository repo)
  (check-equal? '("Stashes (1)…") (lines-starting "Stashes"))
  (ui:show-section! (git-status-test:view) (git-status-test:section '(stashes . #f)))
  (check-equal? (list "Stashes (1)" (string-append "stash@{0} WIP on main: " (short-name repo "HEAD") " long"))
                (list-head (member "Stashes (1)" (git-status-test:status)) 2))
  (check-equal? '("stash@{0}") (face-texts "git-status.stash")))

(test "entries added to git-status:sections and git-status:headers show among the plugin's own, by depth"
  (let ([notes (lambda (repository status) (list (ui:section '((type . notes) (value . #f)) "Notes" "a note")))]
        [user (lambda (repository status) (list (list "User:     Tuna")))])
    (hooks:add! git-status:sections notes 15)
    (hooks:add! git-status:headers user 15)
    (git-mode:refresh-repository repo)
    (hooks:remove! git-status:sections notes)
    (hooks:remove! git-status:headers user)
    (check-equal? '("Head:     main long" "Merge:    origin/main First commit" "User:     Tuna") (list-head (git-status-test:status) 3))
    (check-equal? '("Notes" "a note" "Staged changes (1)") (list-head (member "Notes" (git-status-test:status)) 3))
    (git-mode:refresh-repository repo)))

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
    (check-equal? '("M  a.py\n" #t #t) (list (git-status-test:short "fresh" "a.py") (= before (views:point v)) (eq? v (git-status-test:view))))
    (git-status-test:click-button! "staged" "a.py" "Unstage")
    (check-equal? " M a.py\n" (git-status-test:short "fresh" "a.py"))
    (git-status-test:answer! #t)
    (git-status-test:click-button! "unstaged" "a.py" "Discard")
    (check-equal? '(("Discard unstaged changes in \"a.py\"? ") "" #t)
                  (list (git-status-test:take-asked!) (git-status-test:short "fresh" "a.py") (= before (views:point v))))))

(test "a hunk's button stages the hunk, and a list's button the list"
  (ui:show-section! (git-status-test:view) (git-status-test:section '(file . "long.txt") '(unstaged . #f)))
  (git-status-test:click-button! "unstaged" "@@ -1,5 +1,5 @@" "Stage")
  (check-equal? " long.txt | 2 +-\n 1 file changed, 1 insertion(+), 1 deletion(-)\n"
                (git-status-test:git-out "fresh" "diff" "--cached" "--stat" "long.txt"))
  (git-status-test:answer! #t)
  (git-status-test:click-button! "unstaged" "Unstaged changes" "Stage")
  (check-equal? '("Stage all changes? ") (git-status-test:take-asked!))
  (check-equal? "M  b.txt\nD  gone.txt\nM  long.txt\n?? folder/\n?? new.txt\n?? u1.txt\n?? u2.txt\n" (git-status-test:short "fresh")))

(test "a refresh keeps each section's visibility, and a new section takes its first visibility"
  (git! "fresh" "reset" "-q")
  (git-mode:refresh-repository repo)
  (ui:show-section! (git-status-test:view) (git-status-test:section '(file . "b.txt") '(unstaged . #f)))
  (git-test/repositories:write-file! "fresh/c.txt" "c\n")
  (git! "fresh" "add" "c.txt")
  (git-status-test:press! "g")
  (check-equal? '("Unstaged changes (3)" "modified   b.txt" "@@ -1,8 +1,8 @@" " alpha" "-beta" "+BETA" " gamma" " delta" " epsilon" " zeta"
                  "-eta" "+ETA" " theta" "deleted    gone.txt…" "modified   long.txt")
                (list-head (member "Unstaged changes (3)" (git-status-test:status)) 15))
  (check (member "new file   c.txt…" (git-status-test:status))))
