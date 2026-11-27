(import (tuna) (test) (caught-reports) (test-user) (options) (ask) (modes) (document) (buffers) (views) (layout)
        (layout-split) (editing) (echo-area) (minibuffer) (completion) (files) (undo) (dired) (dired-test))

(define (reports-during thunk)
  (map (lambda (c) (if (cancelled? c) 'cancelled (list (condition-who c) (condition-message c))))
       (caught-reports:during thunk)))

(dired-test:touch! "src/b.txt" "bee\n")
(dired-test:touch! "src/A.txt" "a\n")
(dired-test:touch! "src/.hidden" "")
(dired-test:folder! "src/sub")
(dired-test:touch! "src/sub/inner.txt" "in\n")

(define b (dired:visit (dired-test:home-path "src")))

(define (marks) (dired-test:lines b))

(test "a listing is named after its folder's path with ~ and a final /, lists . and .. first, then names by name with case folded, and is in dired:mode, lighter Folder"
  (check-equal? (list "~/src/" (dired-test:home-path "src/") dired:mode "Folder")
    (list (buffers:name b) (dired:folder b) (modes:major-mode b) (modes:lighter dired:mode)))
  (check-equal? '("  ." "  .." "  .hidden" "  A.txt" "  b.txt" "  sub") (marks)))

(test "visiting again returns the same listing, through files:visit too, and two names for one folder find one listing"
  (check (eq? b (dired:visit (string-append (dired-test:home-path "src") "/sub/.."))))
  (check (eq? b (files:visit (dired-test:home-path "src")))))

(test "point starts on the first entry after . and ..; n and p move by entries, as does every key bound to next-line"
  (layout:switch-to-buffer b)
  (dired:open (dired-test:home-path "src"))
  (check-equal? ".hidden" (dired-test:point-name))
  (test-user:press! "n n")
  (check-equal? "b.txt" (dired-test:point-name))
  (test-user:press! "C-n p p p")
  (check-equal? ".hidden" (dired-test:point-name))
  (check-equal? '((dired:previous-line "beginning of buffer")) (reports-during (lambda () (test-user:press! "p p p"))))
  (check-equal? "." (dired-test:point-name)))

(test "marks are edits: m marks and moves on, undo takes a mark back, the listing is then modified, and . and .. are never marked"
  (test-user:press! "m m m")
  (check-equal? '("  ." "  .." "* .hidden" "  A.txt" "  b.txt" "  sub") (marks))
  (check-equal? "A.txt" (dired-test:point-name))
  (check (buffers:modified? b))
  (test-user:press! "C-/")
  (check-equal? '("  ." "  .." "  .hidden" "  A.txt" "  b.txt" "  sub") (marks)))

(test "d flags D, u unmarks, DEL moves up and unmarks, U removes every mark, and t toggles * and unmarked, leaving other marks"
  (dired-test:goto! "A.txt")
  (test-user:press! "d m m")
  (check-equal? '("  ." "  .." "  .hidden" "D A.txt" "* b.txt" "* sub") (marks))
  (test-user:press! "DEL")
  (check-equal? '("b.txt" (#f #f #f #\D #f #\*)) (list (dired-test:point-name) (map dired:entry-mark (dired-test:entries b))))
  (test-user:press! "t")
  (check-equal? '("  ." "  .." "* .hidden" "D A.txt" "* b.txt" "  sub") (marks))
  (test-user:press! "U")
  (check-equal? '("  ." "  .." "  .hidden" "  A.txt" "  b.txt" "  sub") (marks)))

(test "a prefix repeats, and a negative one marks the entries above"
  (dired-test:goto! "b.txt")
  (test-user:press! "2 m")
  (check-equal? '("sub" ("  ." "  .." "  .hidden" "  A.txt" "* b.txt" "* sub")) (list (dired-test:point-name) (marks)))
  (test-user:press! "U")
  (dired-test:goto! "sub")
  (test-user:press! "- 2 m")
  (check-equal? '("A.txt" ("  ." "  .." "  .hidden" "* A.txt" "* b.txt" "  sub")) (list (dired-test:point-name) (marks)))
  (test-user:press! "U"))

(test "with the region active, m marks every entry whose name the region touches"
  (dired-test:goto! "A.txt")
  (test-user:press! "C-SPC n n m")
  (check-equal? '("  ." "  .." "  .hidden" "* A.txt" "* b.txt" "  sub") (marks))
  (test-user:press! "U"))

(test "* / marks folders, * @ links and * * executable files, and a prefix unmarks"
  (dired-test:symlink! "A.txt" "src/link")
  (chmod (dired-test:home-path "src/b.txt") #o755)
  (dired-test:press-until-read! "g")
  (test-user:press! "* /")
  (check-equal? '("  ." "  .." "  .hidden" "  A.txt" "  b.txt" "  link" "* sub") (marks))
  (test-user:press! "* @ * *")
  (check-equal? '("  ." "  .." "  .hidden" "  A.txt" "* b.txt" "* link" "* sub") (marks))
  (test-user:press! "C-u * /")
  (check-equal? '("  ." "  .." "  .hidden" "  A.txt" "* b.txt" "* link" "  sub") (marks))
  (test-user:press! "U"))

(test "killing a marked listing asks nothing, and C-x C-s in it asks for no file and writes nothing, since files:offer-save? is #f there"
  (dired-test:goto! "A.txt")
  (test-user:press! "m")
  (check-equal? '(#t #f #t) (list (buffers:modified? b) (buffers:with-buffer b (files:offer-save?)) (files:offer-save?)))
  (options:set! ask:file-name-reader (dired-test:answer "~/saved.txt"))
  (options:set! ask:y-or-n-reader (dired-test:answer #t))
  (test-user:press! "C-x C-s")
  (check-equal? (list '() #f #f "~/src/") (list (dired-test:questions) (dired-test:exists? "saved.txt") (files:path b) (buffers:name b)))
  (options:unset! ask:file-name-reader)
  (options:unset! ask:y-or-n-reader))

(test "g reads the folder again, keeping marks by name and each view's point on its entry, with the history of entries that did not change"
  (dired-test:touch! "src/0new.txt" "")
  (dired-test:goto! "b.txt")
  (dired-test:press-until-read! "g")
  (check-equal? '("b.txt" ("  ." "  .." "  .hidden" "  0new.txt" "* A.txt" "  b.txt" "  link" "  sub"))
    (list (dired-test:point-name) (marks)))
  (test-user:press! "C-/")
  (check-equal? '("  ." "  .." "  .hidden" "  0new.txt" "  A.txt" "  b.txt" "  link" "  sub") (marks)))
