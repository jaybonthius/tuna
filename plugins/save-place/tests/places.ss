(import (tuna) (test) (options) (buffers) (views) (files) (save-place-test visits) (save-place))

(define (place name) (assoc (save-place-test/visits:home-file name) (save-place:places)))

(test "a file whose buffer is killed reopens where it was left, and its place is its path and point"
  (save-place-test/visits:write-file! "a.txt" "one\ntwo\nthree\nfour\nfive\n")
  (save-place-test/visits:leave! "a.txt" 9)
  (check-equal? 9 (save-place-test/visits:reopened-point "a.txt"))
  (check-equal? (cons (save-place-test/visits:home-file "a.txt") 9) (place "a.txt")))

(test "leaving a file at its start keeps no place and forgets the one it had"
  (save-place-test/visits:write-file! "start.txt" "one\ntwo\n")
  (save-place-test/visits:leave! "start.txt" 5)
  (save-place-test/visits:leave! "start.txt" 1)
  (check-equal? #f (place "start.txt"))
  (check-equal? #f (save-place-test/visits:reopened-point "start.txt")))

(test "the files a version control tool has the user edit keep no place"
  (save-place-test/visits:write-file! "COMMIT_EDITMSG" "Fix it\n\nMore\n")
  (save-place-test/visits:leave! "COMMIT_EDITMSG" 5)
  (check-equal? #f (place "COMMIT_EDITMSG"))
  (check-equal? '(#t #t #t #t #f)
    (map (save-place:ignored-file-predicate)
         '("/r/.git/COMMIT_EDITMSG" "/tmp/svn-commit.tmp" "/tmp/hg-editor-x1.txt" "/tmp/bzr_log.ab"
           "/tmp/notes.txt"))))

(test "the save-place:limit most recently left places are kept, the latest first"
  (for-each (lambda (name) (save-place-test/visits:write-file! name "one\ntwo\n")) '("x.txt" "y.txt" "z.txt"))
  (options:with ([save-place:limit 2])
    (save-place-test/visits:leave! "x.txt" 3)
    (save-place-test/visits:leave! "y.txt" 4)
    (save-place-test/visits:leave! "z.txt" 5)
    (check-equal? (list (cons (save-place-test/visits:home-file "z.txt") 5) (cons (save-place-test/visits:home-file "y.txt") 4))
                  (save-place:places))))

(test "a file changed outside Tuna reopens at the nearest place it has"
  (save-place-test/visits:write-file! "moved.txt" "one\ntwo\nthree\nfour\nfive\n")
  (save-place-test/visits:leave! "moved.txt" 20)
  (save-place-test/visits:write-file! "moved.txt" "short\n")
  (check-equal? 7 (save-place-test/visits:reopened-point "moved.txt")))

(test "unloading turns save-place off and keeps its places; loading turns it on"
  (save-place-test/visits:write-file! "kept.txt" "one\ntwo\n")
  (save-place-test/visits:write-file! "off.txt" "one\ntwo\n")
  (save-place-test/visits:leave! "kept.txt" 5)
  (unload-owner! (module-owner '(save-place)))
  (save-place-test/visits:leave! "off.txt" 5)
  (load-module! '(save-place))
  (check-equal? (cons (save-place-test/visits:home-file "kept.txt") 5) (place "kept.txt"))
  (check-equal? #f (place "off.txt")))

(test "a temporary visit, as a picker's preview makes, opens the file at its place, and killing it keeps the place"
  (save-place-test/visits:write-file! "preview.txt" "one\ntwo\nthree\n")
  (save-place-test/visits:leave! "preview.txt" 6)
  (let ([b (files:visit-temporarily (save-place-test/visits:home-file "preview.txt"))])
    (check-equal? 6 (views:last-point b))
    (buffers:kill! b))
  (check-equal? (cons (save-place-test/visits:home-file "preview.txt") 6) (place "preview.txt")))
