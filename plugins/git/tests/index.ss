(import (tuna) (test) (git) (git-test repositories))

(define (failure thunk)
  (guard (c [(git:failed-condition? c) (git:failure-summary c)]) (thunk) 'no-failure))

(define (repository name) (git:find-repository (git-test/repositories:path name)))

(define (short repo) (utf8->string (git:query repo '("status" "--short"))))

(git-test/repositories:sample! "repo")

(define repo (repository "repo"))

(test "staging, unstaging and restoring change the index and the working tree, each a logged command"
  (check-equal? " M a.py\nMM b.txt\n D gone.txt\n?? new.txt\n" (short repo))
  (git:stage repo '("a.py" "new.txt"))
  (check-equal? "M  a.py\nMM b.txt\n D gone.txt\nA  new.txt\n" (short repo))
  (git:unstage repo '("a.py"))
  (check-equal? " M a.py\nMM b.txt\n D gone.txt\nA  new.txt\n" (short repo))
  (git:unstage repo #f)
  (check-equal? " M a.py\n M b.txt\n D gone.txt\n?? new.txt\n" (short repo))
  (git:stage-tracked repo)
  (check-equal? "M  a.py\nM  b.txt\nD  gone.txt\n?? new.txt\n" (short repo))
  (git:unstage repo #f)
  (git:stage-all repo)
  (check-equal? "M  a.py\nM  b.txt\nD  gone.txt\nA  new.txt\n" (short repo))
  (git:unstage repo #f)
  (git:stage-intent-to-add repo '("new.txt"))
  (check-equal? " M a.py\n M b.txt\n D gone.txt\n A new.txt\n" (short repo))
  (git:restore-from-index repo '("a.py" "gone.txt"))
  (check-equal? " M b.txt\n A new.txt\n" (short repo))
  (git:stage repo '("b.txt"))
  (git:restore-from-head repo '("b.txt"))
  (check-equal? " A new.txt\n" (short repo))
  (check-equal? '(("add" "--pathspec-from-file=-" "--pathspec-file-nul") ("reset" "-q" "HEAD" "--pathspec-from-file=-" "--pathspec-file-nul")
                  ("reset" "-q" "HEAD" "--") ("add" "-u" ".") ("reset" "-q" "HEAD" "--") ("add" "--all" ".") ("reset" "-q" "HEAD" "--")
                  ("add" "--intent-to-add" "--pathspec-from-file=-" "--pathspec-file-nul")
                  ("checkout" "--pathspec-from-file=-" "--pathspec-file-nul") ("add" "--pathspec-from-file=-" "--pathspec-file-nul")
                  ("checkout" "HEAD" "--pathspec-from-file=-" "--pathspec-file-nul"))
    (map git:command-arguments (git:commands repo))))

(test "paths reach git as bytes, so a path that is not UTF-8 is named exactly"
  (git-test/repositories:write-escaped-file! "repo" "caf\\351.txt")
  (git:stage repo (list (bytevector 99 97 102 233 46 116 120 116)))
  (check-equal? (bytevector 99 97 102 233 46 116 120 116 0) (git:query repo '("diff" "--cached" "--name-only" "-z"))))

(test "before the first commit, unstaging removes from the index"
  (git-test/repositories:git! "" "init" "-q" "-b" "main" "empty")
  (git-test/repositories:write-file! "empty/e.txt" "e\n")
  (git-test/repositories:git! "empty" "add" "e.txt")
  (let ([empty (repository "empty")])
    (git:unstage empty '("e.txt"))
    (check-equal? "?? e.txt\n" (short empty))
    (git:stage empty '("e.txt"))
    (git:unstage empty #f)
    (check-equal? "?? e.txt\n" (short empty))))

(test "git:apply writes the patch's bytes to git's input, and a patch that does not apply fails"
  (let ([patch (string->utf8 "diff --git a/b.txt b/b.txt\n--- a/b.txt\n+++ b/b.txt\n@@ -1,3 +1,3 @@\n alpha\n-beta\n+BETA\n gamma\n")])
    (git:apply repo patch '("--cached"))
    (check-equal? "b.txt\ncaf\xFFFD;.txt\n" (utf8->string (git:query repo '("diff" "--cached" "--name-only"))))
    (check-equal? "b.txt: patch does not apply" (failure (lambda () (git:apply repo patch '("--cached")))))
    (check-equal? "not a bytevector"
      (guard (c [(assertion-violation? c) (condition-message c)]) (git:apply repo "text" '())))))
