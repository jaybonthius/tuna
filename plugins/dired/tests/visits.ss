(import (tuna) (test) (caught-reports) (test-runner) (test-user) (options) (ask) (processes) (document) (buffers) (views)
        (layout) (layout-split) (editing) (echo-area) (minibuffer) (completion) (files) (undo) (dired) (dired-test))

(define (message) (echo-area:current-message))

(dired-test:touch! "v/sub/deep.txt" "deep\n")
(dired-test:touch! "v/f.txt" "f\n")

(define started #f)

(define (shown-and-point) (list (dired-test:shown) (dired-test:point-name)))

(test "C-x d reads a folder, starting in files:directory, or in the listing's folder from a listing, and shows its listing"
  (options:set! ask:file-name-reader (lambda (q folder) (set! started (list q folder)) "~/v"))
  (dired-test:press-until-shown! "C-x d" "~/v/")
  (check-equal? (list (list "Folder: " (dired-test:home-path "")) '((("~/v/" #t)) "f.txt")) (list started (shown-and-point)))
  (test-user:press! "C-x d")
  (check-equal? (list "Folder: " (dired-test:home-path "v/")) started)
  (options:unset! ask:file-name-reader))

(test "RET visits the entry at point, a folder showing its listing; C-x C-j from a file shows its folder's listing on it; ^ shows the parent's on the folder"
  (dired-test:goto! "sub")
  (dired-test:press-until-shown! "RET" "~/v/sub/")
  (check-equal? '((("~/v/sub/" #t)) "deep.txt") (shown-and-point))
  (dired-test:press-until-shown! "RET" "deep.txt")
  (check-equal? '(("deep.txt" #t)) (dired-test:shown))
  (dired-test:press-until-shown! "C-x C-j" "~/v/sub/")
  (check-equal? '((("~/v/sub/" #t)) "deep.txt") (shown-and-point))
  (dired-test:press-until-shown! "^" "~/v/")
  (check-equal? '((("~/v/" #t)) "sub") (shown-and-point))
  (dired-test:press-until-shown! "^" "~/")
  (check-equal? '((("~/" #t)) "v") (shown-and-point)))

(define (wait-for-shown expected) (test-runner:wait-until (lambda () (equal? expected (dired-test:shown)))))

(test "o shows the entry in another view and selects it; C-o leaves the listing selected; q quits the view"
  (dired-test:press-until-shown! "RET" "~/v/")
  (test-user:press! "C-x 3")
  (layout:switch-to-buffer (buffers:find "*scratch*"))
  (test-user:press! "C-x o")
  (dired-test:goto! "f.txt")
  (test-user:press! "C-o")
  (wait-for-shown '(("f.txt" #f) ("~/v/" #t)))
  (dired-test:goto! "sub")
  (test-user:press! "o")
  (wait-for-shown '(("~/v/sub/" #t) ("~/v/" #f)))
  (test-user:press! "q")
  (check-equal? '(("f.txt" #t) ("~/v/" #f)) (dired-test:shown)))

(test "a click on a name opens it as o does, so a name is marked clickable"
  (check (for-all (lambda (e)
                    (let ([mark (test-user:element-attribute e "data-keymap")])
                      (string=? " clickable" (substring mark (- (string-length mark) 10) (string-length mark)))))
                  (dired-test:drawn "dired-name")))
  (test-user:press! "C-x o")
  (dired-test:click-name! "sub")
  (wait-for-shown '(("~/v/sub/" #t) ("~/v/" #f))))

(test "the header's path parts are links to their folders' listings"
  (test-user:press! "C-x o")
  (dired-test:click-link! "~/")
  (wait-for-shown '(("~/v/sub/" #f) ("~/" #t))))

(define (set-time! path date)
  (let-values ([(status output errors) (processes:run "touch" (list "-d" date path) #f)])
    (unless (eqv? status 0) (error 'set-time! "touch failed" path errors))))

(test "visiting a listing whose folder changed says so, or reads it again with dired:refresh-when-revisited?"
  (set-time! (dired-test:home-path "v") "2020-01-01")
  (let ([v (dired:visit (dired-test:home-path "v"))])
    (dired:refresh v)
    (dired-test:touch! "v/g.txt" "g\n")
    (echo-area:message! "")
    (check (eq? v (dired:visit (dired-test:home-path "v"))))
    (check-equal? '("Folder changed on disk; type g to refresh" ("  ." "  .." "  f.txt" "  sub")) (list (message) (dired-test:lines v)))
    (options:set! dired:refresh-when-revisited? #t)
    (check (eq? v (dired:visit (dired-test:home-path "v"))))
    (check-equal? '("  ." "  .." "  f.txt" "  g.txt" "  sub") (dired-test:lines v))
    (options:unset! dired:refresh-when-revisited?)))

(define (delete-tree! path)
  (if (file-directory? path)
      (begin (for-each (lambda (n) (delete-tree! (string-append path "/" n))) (directory-list path)) (delete-directory path))
      (delete-file path)))

(test "a listing whose folder is gone stays as it was read, and g raises no such folder, naming it"
  (let ([gone (dired:visit (dired-test:home-path "v/sub"))])
    (delete-tree! (dired-test:home-path "v/sub"))
    (check-raises (lambda (c) (and (error? c) (eq? 'dired:refresh (condition-who c)) (equal? "no such folder" (condition-message c))
                                   (equal? '("~/v/sub/") (condition-irritants c))))
      (dired:refresh gone))
    (check-equal? '("  ." "  .." "  deep.txt") (dired-test:lines gone))))

(test "visiting a file or a missing path raises"
  (check-raises (lambda (c) (and (error? c) (eq? 'dired:visit (condition-who c)))) (dired:visit (dired-test:home-path "v/f.txt")))
  (check-raises (lambda (c) (and (error? c) (eq? 'dired:visit (condition-who c)) (equal? "failed for ~/v/none: no such file or directory" (condition-message c))))
    (dired:visit (dired-test:home-path "v/none"))))

(test "a home reached through a symbolic link names a listing, and a worker's failure, with ~ too"
  (let ([home (getenv "HOME")])
    (dired-test:symlink! home (string-append "../" (path-last home) "-link"))
    (dired-test:folder! "linked")
    (putenv "HOME" (string-append home "-link"))
    (check-equal? "~/linked/" (buffers:name (dired:visit "~/linked")))
    (check-raises (lambda (c) (equal? "failed for ~/v/none: no such file or directory" (condition-message c))) (dired:visit "~/v/none"))
    (putenv "HOME" home)))

(define (on-last-entry place view)
  (place view)
  (let ([last (car (reverse (dired-test:entries (views:buffer view))))])
    (views:set-point! view (+ 1 (document:node-start last)))))

(test "advice on dired:place-point! starts point elsewhere, as Emacs's dired-initial-position-hook does"
  (dired-test:touch! "w/a.txt" "a\n")
  (dired-test:touch! "w/b.txt" "b\n")
  (advice-add! dired:place-point! on-last-entry)
  (options:set! ask:file-name-reader (lambda (q folder) "~/w"))
  (dired-test:press-until-shown! "C-x d" "~/w/")
  (check-equal? "b.txt" (dired-test:point-name))
  (options:unset! ask:file-name-reader)
  (advice-remove! dired:place-point! on-last-entry))
