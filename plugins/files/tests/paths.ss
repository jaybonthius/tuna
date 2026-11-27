(import (tuna) (test) (files) (files paths) (files-test))

(define home (getenv "HOME"))

(test "files:abbreviated-path writes the home folder as ~, and leaves whole a name that only starts as the home folder's does"
  (check-equal? (list "~" "~/" "~/a/b.txt" (string-append home "x/a") "/etc/hosts")
    (map files:abbreviated-path
         (list home (string-append home "/") (string-append home "/a/b.txt") (string-append home "x/a") "/etc/hosts")))
  (check-raises assertion-violation? (files:abbreviated-path 'notes)))

(test "a home of / is left alone, as Emacs leaves it"
  (putenv "HOME" "/")
  (let ([abbreviated (files:abbreviated-path "/")])
    (putenv "HOME" home)
    (check-equal? "/" abbreviated)))

(test "a home reached through a symbolic link is written as ~ in a buffer's path and in the message of a job's failure"
  (let ([linked (string-append home "-link")])
    (files-test:symlink! home linked)
    (putenv "HOME" linked)
    (files-test:write-text! "~/notes.txt" "n\n")
    (let ([notes (files:visit "~/notes.txt")])
      (check-equal? (string-append home "/notes.txt") (files:path notes))
      (check-equal? '("~/notes.txt" "~/notes.txt" "~")
        (map files:abbreviated-path (list (files:path notes) (string-append linked "/notes.txt") linked))))
    (check-equal? (list (string-append home "/none") "failed for ~/none: no such file or directory")
      (guard (c [(i/o-filename-error? c) (list (i/o-error-filename c) (condition-message c))])
        (files:rename-file "~/none" "~/other")))
    (putenv "HOME" home)))

(define (by-link abbreviate path)
  (abbreviate (or (files:renamed-path path (string-append home "/data") (string-append home "/code")) path)))

(test "advice on files:abbreviated-path names other folders in every message, as Emacs's directory-abbrev-alist does"
  (files-test:folder! "~/data")
  (files-test:symlink! (files-test:expand "~/data") "~/code")
  (advice-add! files:abbreviated-path by-link)
  (check-equal? "~/code/tuna" (files:abbreviated-path (string-append home "/data/tuna")))
  (check-equal? "failed for ~/code/none: no such file or directory"
    (guard (c [(i/o-filename-error? c) (condition-message c)]) (files:rename-file "~/code/none" "~/code/other")))
  (advice-remove! files:abbreviated-path by-link))

(test "true-path makes a path absolute, from ~ too, and resolves the links in the folders that exist"
  (files-test:folder! "~/real")
  (files-test:symlink! (files-test:expand "~/real") "~/alias")
  (check-equal? (list (string-append home "/real/new.txt") home) (list (true-path "~/alias/new.txt") (true-path "~"))))

(test "files:expanded-path is its inverse, as Emacs's expand-file-name: ~ from HOME, a relative path against a folder, . and .. removed without reading the disk, a final / kept"
  (check-equal? (list "/a/b/c" "/a/b/c/" "/a/b/d" "/a" "/x" "/a/c" "/a/b/c/" "/a/b/" "/a/b" home (string-append home "/x/"))
    (map (lambda (p) (files:expanded-path p "/a/b"))
         (list "c" "c/" "./c/../d" ".." "../../../x" "/a/b/../c" "/a/./b//c/" "" "." "~" "~/src/../x/")))
  (check-equal? (string-append (current-directory) "/x") (files:expanded-path "x"))
  (check-raises assertion-violation? (files:expanded-path "~root/x"))
  (check-raises assertion-violation? (files:expanded-path "x" "relative")))
