#!tuna
(define c-link (begin (load-shared-object #f) (foreign-procedure "link" (string string) int)))
(define c-symlink (foreign-procedure "symlink" (string string) int))
(define c-stat (foreign-procedure "stat" (string uptr) int))

(define (expand path)
  (if (and (>= (string-length path) 2) (string=? (substring path 0 2) "~/"))
      (string-append (getenv "HOME") (substring path 1 (string-length path)))
      path))

(define (write-bytes! path bytes)
  (call-with-port (open-file-output-port (expand path) (file-options no-fail))
    (lambda (p) (put-bytevector p bytes))))

(define (write-text! path text) (write-bytes! path (string->utf8 text)))

(define (read-bytes path)
  (let ([bytes (call-with-port (open-file-input-port (expand path)) get-bytevector-all)])
    (if (eof-object? bytes) #vu8() bytes)))

(define (read-text path) (utf8->string (read-bytes path)))

(define (link! from to) (c-link (expand from) (expand to)))

(define (symlink! target link) (c-symlink (expand target) (expand link)))

(define (link-count path)
  (let ([buffer (foreign-alloc 144)])
    (c-stat (expand path) buffer)
    (let ([n (foreign-ref 'unsigned-64 buffer 16)])
      (foreign-free buffer)
      n)))

(define (mode path) (get-mode (expand path)))

(define (set-mode! path mode) (chmod (expand path) mode))

(define (symlink? path) (file-symbolic-link? (expand path)))

(define (folder! path) (mkdir (expand path)))

(define (folder-files path) (list-sort string<? (directory-list (expand path))))

(define (exists? path) (file-exists? (expand path)))

(define (fnv bytes)
  (let loop ([i 0] [h 2166136261])
    (if (= i (bytevector-length bytes))
        h
        (loop (+ i 1) (bitwise-and (* (bitwise-xor h (bytevector-u8-ref bytes i)) 16777619) #xFFFFFFFF)))))
