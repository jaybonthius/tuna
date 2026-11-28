(import (tuna) (test) (buffers) (dired) (dired-test))

(dired-test:touch! "s/f.txt" "f\n")

(define (stale? listing) (buffers:with-buffer listing ((buffers:stale-function) listing)))

(test "a listing's buffers:stale-function, which dired's mode hook sets beside its reverter, is false while the folder is as read, and true once an entry is made, even in the clock tick the folder was read in"
  (let ([s (dired:visit (dired-test:home-path "s"))])
    (check-equal? #f (stale? s))
    (dired-test:touch! "s/g.txt" "g\n")
    (check-equal? #t (stale? s))
    (dired:refresh s)
    (check-equal? #f (stale? s))
    (delete-file (dired-test:home-path "s/g.txt"))
    (check-equal? #t (stale? s))))

(test "a listing whose folder is gone is not stale, so nothing reads it again until the user asks"
  (dired-test:touch! "s/sub/h.txt" "h\n")
  (let ([sub (dired:visit (dired-test:home-path "s/sub"))])
    (delete-file (dired-test:home-path "s/sub/h.txt"))
    (delete-directory (dired-test:home-path "s/sub"))
    (check-equal? #f (stale? sub))))
