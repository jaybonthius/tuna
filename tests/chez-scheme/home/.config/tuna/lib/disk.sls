#!tuna
(define (expand path)
  (if (and (>= (string-length path) 2) (string=? (substring path 0 2) "~/"))
      (string-append (getenv "HOME") (substring path 1 (string-length path)))
      path))

(define (write-text! path text)
  (call-with-port (open-file-output-port (expand path) (file-options no-fail))
    (lambda (p) (put-bytevector p (string->utf8 text)))))

(define (folder! path) (mkdir (expand path)))
