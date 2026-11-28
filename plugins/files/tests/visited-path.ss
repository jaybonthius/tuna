(import (tuna) (test) (hooks) (buffers) (files) (files-test))

(define changes '())

(define (note-change buffer old new) (set! changes (cons (list (buffers:name buffer) old new) changes)))

(define (taken!) (let ([c (reverse changes)]) (set! changes '()) c))

(define (home name) (files-test:expand (string-append "~/" name)))

(hooks:add! files:visited-path-changed note-change)

(files-test:write-text! "~/a.txt" "a\n")

(test "files:write-file to a new path runs files:visited-path-changed with the buffer, the old path and the new, once the buffer visits the new path"
  (let ([a (files:visit "~/a.txt")])
    (files:write-file "~/b.txt" a)
    (check-equal? (list (list "b.txt" (home "a.txt") (home "b.txt"))) (taken!))
    (files:write-file "~/b.txt" a)
    (check-equal? '() (taken!))))

(test "a buffer that visited no file passes #f as its old path"
  (let ([draft (buffers:make "*draft*" "draft\n")])
    (files:write-file "~/draft.txt" draft)
    (check-equal? (list (list "draft.txt" #f (home "draft.txt"))) (taken!))))

(test "the hook runs before the write, so it runs even when the write then fails"
  (let ([c (buffers:make "*c*" "c\n")])
    (check-raises error? (files:write-file "~/missing/c.txt" c))
    (check-equal? (list (list "c.txt" #f (home "missing/c.txt"))) (taken!))
    (check-equal? (home "missing/c.txt") (files:path c))))

(test "files:rename-file runs it for each buffer it moves"
  (files-test:folder! "~/dir")
  (files-test:write-text! "~/dir/x.txt" "x\n")
  (let ([x (files:visit "~/dir/x.txt")])
    (files:rename-file "~/dir" "~/moved")
    (check-equal? (list (list "x.txt" (home "dir/x.txt") (home "moved/x.txt"))) (taken!))
    (check-equal? (home "moved/x.txt") (files:path x))))
