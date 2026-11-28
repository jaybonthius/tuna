(import (tuna) (test) (test-runner) (test-user) (options) (document) (buffers) (views) (dired) (files) (auto-revert)
        (files-test) (file-watch-test) (auto-revert-test) (dired-test))

(define (home name) (file-watch-test:home name))

(file-watch-test:folder! "src")
(file-watch-test:write! "src/a.txt" "a\n")
(file-watch-test:write! "src/b.txt" "b\n")

(define listing (dired:visit (home "src")))

(define v (auto-revert-test:show! listing))

(define (point-name) (dired-test:entry-name (dired:entry-at v)))

(test "with auto-revert:non-file-buffers? left #f, a listing is not watched, and a revisit does what dired:refresh-when-revisited? says"
  (check-equal? 0 (auto-revert-test:inotify-watches))
  (file-watch-test:write! "src/new.txt" "new\n")
  (files-test:take-said!)
  (dired:visit (home "src"))
  (check-equal? '(("  ." "  .." "  a.txt" "  b.txt") ("Folder changed on disk; type g to refresh")) (list (dired-test:lines listing) (files-test:take-said!)))
  (options:set! dired:refresh-when-revisited? #t)
  (dired:visit (home "src"))
  (check-equal? '("  ." "  .." "  a.txt" "  b.txt" "  new.txt") (dired-test:lines listing))
  (options:unset! dired:refresh-when-revisited?)
  (delete-file (home "src/new.txt"))
  (dired:refresh listing))

(test "with it #t, a listing is watched at its folder, and an entry made or deleted there refreshes it, keeping its marks and point"
  (options:set! auto-revert:non-file-buffers? #t)
  (views:set-point! v (document:node-start (car (filter (lambda (e) (equal? "a.txt" (dired-test:entry-name e))) (dired-test:entries listing)))))
  (test-user:press! "m")
  (check-equal? '(("  ." "  .." "* a.txt" "  b.txt") "b.txt") (list (dired-test:lines listing) (point-name)))
  (file-watch-test:write! "src/c.txt" "c\n")
  (test-runner:wait-until (lambda () (equal? '("  ." "  .." "* a.txt" "  b.txt" "  c.txt") (dired-test:lines listing))))
  (check-equal? "b.txt" (point-name))
  (delete-file (home "src/c.txt"))
  (test-runner:wait-until (lambda () (equal? '("  ." "  .." "* a.txt" "  b.txt") (dired-test:lines listing))))
  (check-equal? "b.txt" (point-name))
  (options:unset! auto-revert:non-file-buffers?))
