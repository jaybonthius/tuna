(import (tuna) (test) (eval-test caught-reports) (test-runner) (test-user) (options) (ask) (document) (buffers) (views) (layout)
        (layout-split) (editing) (echo-area) (minibuffer) (completion) (files) (undo) (dired) (dired-test))

(dired-test:touch! "here/a.txt" "a\n")
(dired-test:touch! "here/b.txt" "b\n")
(dired-test:folder! "there")

(define here (dired:visit (dired-test:home-path "here")))

(define there (dired:visit (dired-test:home-path "there")))

(define started #f)

(define names-while-asking #f)

(define (note-start question folder)
  (set! started folder)
  (set! names-while-asking
    (let ([names (buffers:find " *Marked Files*")])
      (and names (pair? (views:showing names)) (document:text (buffers:document names)))))
  "~/there/")

(test "with dired:other-listing-target?, R of several files starts in the other listing's folder, though their names take that listing's view while it asks"
  (layout:switch-to-buffer there)
  (test-user:press! "C-x 3")
  (layout:switch-to-buffer here)
  (options:set! layout-split:split-width-threshold #f)
  (options:set! layout-split:split-height-threshold #f)
  (options:set! dired:other-listing-target? #t)
  (options:set! ask:file-name-reader note-start)
  (dired-test:goto! "a.txt")
  (test-user:press! "m m")
  (check-equal? "Moved 2 files" (dired-test:press-for-message! "R"))
  (check-equal? (list (dired-test:home-path "there/") "a.txt\nb.txt\n") (list started names-while-asking))
  (check-equal? '("  ." "  .." "* a.txt" "* b.txt") (dired-test:lines there)))
