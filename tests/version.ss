(import (test) (processes) (tuna version))

(define (string-suffix? suffix s)
  (let ([n (string-length suffix)] [m (string-length s)])
    (and (<= n m) (string=? suffix (substring s (- m n) m)))))

(define (hex-digit? c) (or (char<=? #\0 c #\9) (char<=? #\a c #\f)))

(define commit
  (if (string-suffix? "-dirty" tuna-version)
      (substring tuna-version 0 (- (string-length tuna-version) (string-length "-dirty")))
      tuna-version))

(test "the version is a commit, marked dirty when the tree had changes"
  (check (>= (string-length commit) 7))
  (check (for-all hex-digit? (string->list commit))))

(test "the version names a commit of the repository Tuna was built in"
  (let-values ([(status output errors)
                (processes:run "git" (list "cat-file" "-e" (string-append commit "^{commit}")) #f
                  (processes:options [directory (path-parent (car (command-line)))]))])
    (check-equal? 0 status)))
