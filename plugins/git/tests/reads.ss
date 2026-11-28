(import (tuna) (test) (diff) (git) (git-test repositories))

(define git! git-test/repositories:git!)

(define write-file! git-test/repositories:write-file!)

(define (out . arguments) (utf8->string (apply git! "repo" arguments)))

(define (trimmed s) (substring s 0 (- (string-length s) 1)))

(git-test/repositories:sample! "repo")

(define repo (git:find-repository (git-test/repositories:path "repo")))

(define (lines bytes)
  (let loop ([cs (string->list (utf8->string bytes))] [line '()] [acc '()])
    (cond
      [(null? cs) (reverse (if (null? line) acc (cons (list->string (reverse line)) acc)))]
      [(char=? (car cs) #\newline) (loop (cdr cs) '() (cons (list->string (reverse line)) acc))]
      [else (loop (cdr cs) (cons (car cs) line) acc)])))

(define (named files . names) (filter (lambda (f) (member (diff:file-path f) names)) files))

(define (first-words bytes)
  (map (lambda (l) (let loop ([i 0]) (if (or (= i (string-length l)) (char=? (string-ref l i) #\space)) (substring l 0 i) (loop (+ i 1)))))
       (lines bytes)))

(test "git:show gives a commit's file diffs; a root commit's files are all added"
  (check-equal? '(("b.txt" modified)) (map (lambda (f) (list (diff:file-path f) (diff:file-status f))) (git:show repo "HEAD" '())))
  (check-equal? '(("a.py" added) ("b.txt" added) ("gone.txt" added))
                (map (lambda (f) (list (diff:file-path f) (diff:file-status f))) (git:show repo "HEAD~1" '())))
  (check-equal? '("@@ -1,2 +1,3 @@") (map (lambda (h) (utf8->string (diff:hunk-heading h))) (diff:file-hunks (car (git:show repo "HEAD" '())))))
  (check-equal? '("@@ -2,0 +3 @@ beta") (map (lambda (h) (utf8->string (diff:hunk-heading h))) (diff:file-hunks (car (git:show repo "HEAD" '("-U0"))))))
  (check-raises git:failed-condition? (git:show repo "no-such-revision" '())))

(test "git:show gives a merge commit's files as combined diffs"
  (git-test/repositories:conflict! "merged")
  (git! "merged" "add" "f.txt")
  (git! "merged" "commit" "-qm" "merge")
  (let ([merged (git:find-repository (git-test/repositories:path "merged"))])
    (check-equal? '(("f.txt" #t)) (map (lambda (f) (list (diff:file-path f) (diff:file-combined? f))) (git:show merged "HEAD" '())))))

(test "git:commit-details gives a commit's hash, refs, author and committer with git's dates, parents and message"
  (git! "repo" "commit" "-q" "--allow-empty" "-m" "Third\n\nThe body.\n")
  (let ([d (git:commit-details repo "HEAD")])
    (check (git:details? d))
    (check-equal? (list (trimmed (out "rev-parse" "HEAD")) (trimmed (out "rev-parse" "--short" "HEAD")) '("main")
                        "Tuna <tuna@example.org>" (trimmed (out "log" "-1" "--format=%ad")) "Tuna <tuna@example.org>"
                        (trimmed (out "log" "-1" "--format=%cd")) '("Second commit") "Third\n\nThe body.")
                  (list (git:details-name d) (git:details-short-name d) (git:details-refs d) (git:details-author d)
                        (git:details-author-date d) (git:details-committer d) (git:details-committer-date d)
                        (map git:commit-subject (git:details-parents d)) (git:details-message d))))
  (check-equal? '() (git:details-parents (git:commit-details repo "HEAD~2")))
  (check-raises git:failed-condition? (git:commit-details repo "no-such-revision"))
  (check-raises assertion-violation? (git:details-name 'no)))

(test "git:related-refs gives the branches merged into and containing a commit, and the tags it follows and precedes"
  (git! "repo" "branch" "older" "HEAD~1")
  (git! "repo" "tag" "v0" "HEAD~2")
  (git! "repo" "tag" "v1" "HEAD")
  (let ([r (git:related-refs repo "HEAD~1" (git:branch-scope local))])
    (check (git:related? r))
    (check-equal? '(("older") ("main" "older") ("v0" . 1) ("v1" . 1))
                  (list (git:related-merged r) (git:related-contained r) (git:related-follows r) (git:related-precedes r))))
  (let ([r (git:related-refs repo "HEAD~2" (git:branch-scope all))])
    (check-equal? '(("remotes/origin/main") ("main" "older" "remotes/origin/main") ("v0" . 0))
                  (list (git:related-merged r) (git:related-contained r) (git:related-follows r))))
  (let ([r (git:related-refs repo "HEAD~2" (git:branch-scope mixed))])
    (check-equal? '(() ("main" "older" "remotes/origin/main")) (list (git:related-merged r) (git:related-contained r))))
  (check-equal? #f (git:related-precedes (git:related-refs repo "HEAD" (git:branch-scope local))))
  (check-raises assertion-violation? (git:related-refs repo "HEAD" 'everything)))

(test "git:refs gives the local and remote branches and the tags"
  (check-equal? '("main" "older" "origin/main" "v0" "v1") (list-sort string<? (git:refs repo))))

(test "git:diff-with runs git diff through an external program on the file diffs given alone, and returns what it wrote"
  (write-file! "repo/c.txt" "c\n")
  (git! "repo" "add" "c.txt")
  (git! "repo" "commit" "-qm" "c" "--" "c.txt")
  (write-file! "repo/c.txt" "C\n")
  (write-file! "repo/b.txt" "staged\n")
  (git! "repo" "add" "b.txt")
  (check-equal? '("a.py" "c.txt") (first-words (git:diff-with repo '() "echo" (named (git:diff repo '()) "a.py" "c.txt"))))
  (check-equal? '("b.txt") (first-words (git:diff-with repo '("--cached") "echo" (named (git:diff repo '("--cached")) "b.txt"))))
  (git! "repo" "config" "diff.external" "false")
  (check-equal? '("a.py") (first-words (git:diff-with repo '() "echo" (named (git:diff repo '()) "a.py"))))
  (check-equal? '("a.py") (first-words (git:diff-with repo '() "X=1 echo" (named (git:diff repo '()) "a.py"))))
  (check-raises assertion-violation? (git:diff-with repo '() "echo" '("a.py"))))

(test "git:diff-with pairs a rename, giving git both its paths"
  (git! "repo" "mv" "c.txt" "d.txt")
  (let ([written (git:diff-with repo '("--cached" "-M") "echo" (named (git:diff repo '("--cached" "-M")) "d.txt"))])
    (check-equal? "c.txt" (car (first-words written)))
    (check (member "rename to d.txt" (lines written)))))

(test "git:show-with runs git show of a revision through an external program, its paths alone"
  (check-equal? '("b.txt") (first-words (git:show-with repo "HEAD~2" '() "echo" (named (git:show repo "HEAD~2" '()) "b.txt"))))
  (check-equal? '("a.py" "gone.txt") (first-words (git:show-with repo "HEAD~3" '() "echo" (named (git:show repo "HEAD~3" '()) "a.py" "gone.txt")))))
