(import (tuna) (testing) (tuna plugins) (tuna eval))
(use-plugin git)
(import (diff) (processes))

(define home (getenv "HOME"))

(putenv "GIT_AUTHOR_NAME" "Tuna")
(putenv "GIT_AUTHOR_EMAIL" "tuna@example.org")
(putenv "GIT_AUTHOR_DATE" "1767225600 +0000")
(putenv "GIT_COMMITTER_NAME" "Tuna")
(putenv "GIT_COMMITTER_EMAIL" "tuna@example.org")
(putenv "GIT_COMMITTER_DATE" "1767225600 +0000")

(define (sh command)
  (unless (zero? (system (string-append "{ set -e; cd \"$HOME\"; " command "; } < /dev/null > /dev/null 2>&1")))
    (error 'sh "failed" command)))

(define (write-file! path text)
  (sh (string-append "mkdir -p \"$(dirname '" path "')\""))
  (call-with-output-file (string-append home "/" path) (lambda (p) (display text p)) '(replace)))

(define (at path) (string-append home "/" path))


(define (entries s)
  (map (lambda (e) (list (git:entry-path e) (git:entry-original-path e) (git:entry-index e) (git:entry-worktree e)))
       (git:status-entries s)))

(define (log-lines repository)
  (map (lambda (c) (list (git:command-exit c) (git:command-arguments c))) (git:commands repository)))

(define (failure thunk)
  (guard (c [(git:failed-condition? c) (git:failure-summary c)]) (thunk) 'no-failure))

(define (sample-repository! name)
  (sh (string-append "rm -rf " name " origin-" name ".git && git init -q --bare -b main origin-" name ".git"
                     " && git init -q -b main " name))
  (write-file! (string-append name "/a.py") "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n")
  (write-file! (string-append name "/b.txt") "alpha\nbeta\n")
  (write-file! (string-append name "/gone.txt") "gone\n")
  (sh (string-append "cd " name " && git add -A && git commit -qm 'First commit'"
                     " && git remote add origin ../origin-" name ".git && git push -q -u origin main"))
  (write-file! (string-append name "/b.txt") "alpha\nbeta\ngamma\n")
  (sh (string-append "cd " name " && git commit -qam 'Second commit'"))
  (write-file! (string-append name "/a.py") "one\nTWO\nthree\nfour\nfive\nsix\nseven\neight\nNINE\nten\n")
  (write-file! (string-append name "/b.txt") "alpha\nBETA\ngamma\n")
  (sh (string-append "cd " name " && git add b.txt"))
  (write-file! (string-append name "/b.txt") "alpha\nBETA\ngamma\ndelta\n")
  (sh (string-append "cd " name " && rm gone.txt"))
  (write-file! (string-append name "/new.txt") "new\n"))
(import (console))
