(import (tuna) (test) (options) (visits) (save-place))

(define (place name) (assoc (visits:home-file name) (save-place:places)))

(test "a file whose buffer is killed reopens where it was left, and its place is its path and point"
  (visits:write-file! "a.txt" "one\ntwo\nthree\nfour\nfive\n")
  (visits:leave! "a.txt" 9)
  (check-equal? 9 (visits:reopened-point "a.txt"))
  (check-equal? (cons (visits:home-file "a.txt") 9) (place "a.txt")))

(test "leaving a file at its start keeps no place and forgets the one it had"
  (visits:write-file! "start.txt" "one\ntwo\n")
  (visits:leave! "start.txt" 5)
  (visits:leave! "start.txt" 1)
  (check-equal? #f (place "start.txt"))
  (check-equal? #f (visits:reopened-point "start.txt")))

(test "the files a version control tool has the user edit keep no place"
  (visits:write-file! "COMMIT_EDITMSG" "Fix it\n\nMore\n")
  (visits:leave! "COMMIT_EDITMSG" 5)
  (check-equal? #f (place "COMMIT_EDITMSG"))
  (check-equal? '(#t #t #t #t #f)
    (map (save-place:ignored-file-predicate)
         '("/r/.git/COMMIT_EDITMSG" "/tmp/svn-commit.tmp" "/tmp/hg-editor-x1.txt" "/tmp/bzr_log.ab"
           "/tmp/notes.txt"))))

(test "the save-place:limit most recently left places are kept, the latest first"
  (for-each (lambda (name) (visits:write-file! name "one\ntwo\n")) '("x.txt" "y.txt" "z.txt"))
  (options:with ([save-place:limit 2])
    (visits:leave! "x.txt" 3)
    (visits:leave! "y.txt" 4)
    (visits:leave! "z.txt" 5)
    (check-equal? (list (cons (visits:home-file "z.txt") 5) (cons (visits:home-file "y.txt") 4))
                  (save-place:places))))

(test "a file changed outside Tuna reopens at the nearest place it has"
  (visits:write-file! "moved.txt" "one\ntwo\nthree\nfour\nfive\n")
  (visits:leave! "moved.txt" 20)
  (visits:write-file! "moved.txt" "short\n")
  (check-equal? 7 (visits:reopened-point "moved.txt")))

(test "unloading turns save-place off and keeps its places; loading turns it on"
  (visits:write-file! "kept.txt" "one\ntwo\n")
  (visits:write-file! "off.txt" "one\ntwo\n")
  (visits:leave! "kept.txt" 5)
  (unload-owner! (module-owner '(save-place)))
  (visits:leave! "off.txt" 5)
  (load-module! '(save-place))
  (check-equal? (cons (visits:home-file "kept.txt") 5) (place "kept.txt"))
  (check-equal? #f (place "off.txt")))
