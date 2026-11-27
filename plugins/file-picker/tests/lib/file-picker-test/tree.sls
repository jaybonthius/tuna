#!tuna

(define (path name) (string-append (getenv "HOME") "/" name))

(define (write-file! name text)
  (let ([file (path name)])
    (when (file-exists? file #f) (delete-file file))
    (call-with-output-file file (lambda (p) (put-string p text)))))

(define (make-folder! name) (unless (file-exists? (path name)) (mkdir (path name))))

(define %symlink (foreign-procedure "symlink" (string string) int))

(define (link! target name)
  (unless (file-exists? (path name) #f)
    (unless (= 0 (%symlink target (path name)))
      (error 'file-picker-test/tree:link! "cannot link" target name))))

(for-each make-folder! '("src" "notes" "notes/sub" "code" "code/tuna"))
(write-file! "src/text.txt" "needle one\nhay\nneedle two\n")
(write-file! "src/.hidden" "needle hidden\n")
(write-file! "src/blob.bin" "needle\x0;binary\n")
(link! "text.txt" "src/link.txt")
(write-file! "notes/a.txt" "alpha line\nbeta define-record x\ngamma\n")
(write-file! "notes/sub/b.sls" "define-record here\n")
(write-file! "code/tuna/main.sls" "x\n")
