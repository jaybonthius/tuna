(import (tuna) (test) (git) (git-test repositories))

(define (entries s)
  (map (lambda (e) (list (git:entry-path e) (git:entry-original-path e) (git:entry-index e) (git:entry-worktree e)))
       (git:status-entries s)))

(define (names paths) (map utf8->string paths))

(define (syntax-message form)
  (guard (c [(syntax-violation? c) (condition-message c)])
    (eval form (interaction-environment))
    'no-violation))

(define (repository name) (git:find-repository (git-test/repositories:path name)))

(test "git:status reads the branch, HEAD, the upstream and how far ahead and behind, and one entry per changed tracked file"
  (git-test/repositories:sample! "repo")
  (let ([s (git:status (repository "repo"))])
    (check (git:status? s))
    (check-equal? '("main" "origin/main" 1 0)
      (list (git:status-branch s) (git:status-upstream s) (git:status-ahead s) (git:status-behind s)))
    (check-equal? 40 (string-length (git:status-head s)))
    (check (for-all git:entry? (git:status-entries s)))
    (check-equal? '(("a.py" #f unmodified modified) ("b.txt" #f modified modified) ("gone.txt" #f unmodified deleted)) (entries s))
    (check-equal? (list (string->utf8 "new.txt")) (git:status-untracked s))))

(test "renames, intent-to-add and paths with spaces are entries; untracked paths are bytes sorted bytewise, staged as they are"
  (git-test/repositories:sample! "moves")
  (git-test/repositories:git! "moves" "mv" "b.txt" "b c.txt")
  (git-test/repositories:git! "moves" "add" "-N" "new.txt")
  (git-test/repositories:write-file! "moves/caf\xe9;.txt" "x\n")
  (git-test/repositories:write-escaped-file! "moves" "raw\\351")
  (let* ([repo (repository "moves")] [s (git:status repo)])
    (check-equal? '(("a.py" #f unmodified modified) ("b c.txt" "b.txt" renamed modified) ("gone.txt" #f unmodified deleted)
                    ("new.txt" #f unmodified added))
      (entries s))
    (check-equal? (list (string->utf8 "caf\xe9;.txt") (bytevector 114 97 119 233)) (git:status-untracked s))
    (git:stage repo (git:status-untracked s))
    (check-equal? (list (string->utf8 "caf\xe9;.txt") (bytevector 114 97 119 233))
      (map git:entry-path-bytes (filter (lambda (e) (eq? (git:entry-index e) 'added)) (git:status-entries (git:status repo)))))))

(test "untracked files are listed by folder, by file, not at all, or as status.showUntrackedFiles says"
  (git-test/repositories:sample! "listing")
  (git-test/repositories:write-file! "listing/folder/one.txt" "1\n")
  (git-test/repositories:write-file! "listing/folder/two.txt" "2\n")
  (let ([repo (repository "listing")])
    (check-equal? '("folder/" "new.txt") (names (git:untracked repo (git:untracked-listing normal))))
    (check-equal? '("folder/one.txt" "folder/two.txt" "new.txt") (names (git:untracked repo (git:untracked-listing all))))
    (check-equal? '() (git:untracked repo (git:untracked-listing no)))
    (git-test/repositories:git! "listing" "config" "status.showUntrackedFiles" "all")
    (check-equal? '("folder/one.txt" "folder/two.txt" "new.txt") (names (git:untracked repo #f)))
    (check-equal? "universe of untracked-listing does not include specified symbol"
      (syntax-message '(git:untracked-listing sometimes)))))

(test "advice on git:untracked changes what the status lists"
  (let* ([repo (repository "listing")]
         [leave-out (lambda (original repository listing)
                      (filter (lambda (path) (not (string=? (utf8->string path) "folder/one.txt"))) (original repository listing)))])
    (advice-add! git:untracked leave-out)
    (let ([listed (names (git:status-untracked (git:status repo)))])
      (advice-remove! git:untracked leave-out)
      (check-equal? '("folder/two.txt" "new.txt") listed))))

(test "a detached HEAD has no branch, and a repository with no commit has no HEAD"
  (git-test/repositories:sample! "detached")
  (git-test/repositories:git! "detached" "checkout" "-q" "--detach")
  (check-equal? #f (git:status-branch (git:status (repository "detached"))))
  (git-test/repositories:git! "" "init" "-q" "-b" "main" "empty")
  (let ([s (git:status (repository "empty"))])
    (check-equal? '("main" #f #f) (list (git:status-branch s) (git:status-head s) (git:status-upstream s)))))

(test "a conflicted file is unmerged on both sides"
  (git-test/repositories:conflict! "conflict")
  (check-equal? '(("f.txt" #f unmerged unmerged)) (entries (git:status (repository "conflict")))))

(test "a rename's old name keeps its bytes"
  (git-test/repositories:git! "" "init" "-q" "-b" "main" "moved")
  (git-test/repositories:write-escaped-file! "moved" "old\\351")
  (git-test/repositories:git! "moved" "add" "-A")
  (git-test/repositories:git! "moved" "commit" "-qm" "c")
  (git-test/repositories:run! "moved" "sh" "-c" "git mv \"$(printf \"$1\")\" new.txt" "sh" "old\\351")
  (check-equal? (list (list "new.txt" (bytevector 111 108 100 233)))
    (map (lambda (e) (list (git:entry-path e) (git:entry-original-path-bytes e)))
         (git:status-entries (git:status (repository "moved"))))))
