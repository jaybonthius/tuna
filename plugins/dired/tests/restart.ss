(import (test) (test-runner))

(define home (string-append (getenv "HOME") "/restarted"))

(define (passes file)
  (let-values ([(status errors) (test-runner:run-file file home)])
    (check-equal? 0 status)
    (check-equal? "" errors)))

(define (delete-tree! path)
  (if (file-directory? path)
      (begin (for-each (lambda (n) (delete-tree! (string-append path "/" n))) (directory-list path)) (delete-directory path))
      (delete-file path)))

(test "the open listings' folders are saved, so a restart lists them again; one gone since is left out, and a message names it"
  (passes "restart/first.ss")
  (delete-tree! (string-append home "/notes"))
  (passes "restart/second.ss"))
