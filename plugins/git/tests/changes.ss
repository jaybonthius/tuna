(import (tuna) (test) (options) (diff) (git) (git-test repositories))

(define (repository name) (git:find-repository (git-test/repositories:path name)))

(git-test/repositories:sample! "repo")

(define repo (repository "repo"))

(test "git:diff parses git diff's output: the unstaged changes, or with --cached the staged ones"
  (check-equal? '(("a.py" modified 1) ("b.txt" modified 1) ("gone.txt" deleted 1))
    (map (lambda (f) (list (diff:file-path f) (diff:file-status f) (length (diff:file-hunks f)))) (git:diff repo '())))
  (check-equal? '("b.txt") (map diff:file-path (git:diff repo '("--cached")))))

(test "git:diff-arguments are added to every diff"
  (options:set! git:diff-arguments '("-U0"))
  (let ([headings (map (lambda (h) (utf8->string (diff:hunk-heading h))) (diff:file-hunks (car (git:diff repo '()))))])
    (options:unset! git:diff-arguments)
    (check-equal? '("@@ -2 +2 @@ one" "@@ -9 +9 @@ eight") headings)))

(test "a textconv driver does not change the diff, which holds the file's bytes"
  (git-test/repositories:write-file! "repo/.gitattributes" "*.up diff=upper\n")
  (git-test/repositories:git! "repo" "config" "diff.upper.textconv" "tr a-z A-Z <")
  (git-test/repositories:write-file! "repo/t.up" "one\n")
  (git-test/repositories:git! "repo" "add" ".gitattributes" "t.up")
  (git-test/repositories:git! "repo" "commit" "-qm" "t")
  (git-test/repositories:write-file! "repo/t.up" "one\ntwo\n")
  (let ([t (find (lambda (f) (equal? (diff:file-path f) "t.up")) (git:diff repo '()))])
    (check-equal? '("one" "two")
      (map (lambda (l) (utf8->string (diff:line-bytes l))) (vector->list (diff:hunk-lines (car (diff:file-hunks t))))))))

(test "git:commits gives the commits of a range, newest first, at most count"
  (let ([commits (git:commits repo "HEAD" #f)])
    (check (for-all git:commit? commits))
    (check-equal? '(("t" ("main") 40) ("Second commit" () 40) ("First commit" ("origin/main") 40))
      (map (lambda (c) (list (git:commit-subject c) (git:commit-refs c) (string-length (git:commit-name c)))) commits))
    (check (for-all (lambda (c) (string=? (git:commit-short-name c) (substring (git:commit-name c) 0 (string-length (git:commit-short-name c)))))
                    commits)))
  (check-equal? '("t" "Second commit") (map git:commit-subject (git:commits repo "@{upstream}.." 10)))
  (check-equal? '("t") (map git:commit-subject (git:commits repo "HEAD" 1)))
  (git-test/repositories:git! "repo" "tag" "v1" "HEAD~1")
  (check-equal? '("tag: v1") (git:commit-refs (cadr (git:commits repo "HEAD" #f)))))

(test "git:stashes gives each stash's name and message, newest first"
  (check-equal? '() (git:stashes repo))
  (git-test/repositories:git! "repo" "stash" "-q")
  (git-test/repositories:git! "repo" "stash" "-q" "-u")
  (let ([head (git:commit-short-name (car (git:commits repo "HEAD" 1)))])
    (check-equal? (list (cons "stash@{0}" (string-append "WIP on main: " head " t")) (cons "stash@{1}" (string-append "WIP on main: " head " t")))
      (git:stashes repo))))

(test "git:diff gives a conflicted file's unstaged changes as a combined diff"
  (git-test/repositories:conflict! "conflict")
  (check-equal? '(("f.txt" unmerged #t))
    (map (lambda (f) (list (diff:file-path f) (diff:file-status f) (diff:file-combined? f)))
         (git:diff (repository "conflict") '()))))
