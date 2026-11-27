(import (tuna))
(use-plugin diff)

(define home (getenv "HOME"))

(define (sh command)
  (unless (zero? (system (string-append "{ set -e; cd \"$HOME\"; " command "; } < /dev/null > /dev/null")))
    (error 'sh "failed" command)))

(define (bytes-of path) (call-with-port (open-file-input-port (string-append home "/" path)) get-bytevector-all))

(define (show bytes) (display (utf8->string bytes)))

(define (summary file)
  (list (diff:file-old-path file) (diff:file-new-path file) (diff:file-status file)
        (diff:file-binary? file) (diff:file-combined? file) (length (diff:file-hunks file))))

(define (lines-of hunk)
  (map (lambda (line)
         (list (diff:line-kind line) (utf8->string (diff:line-prefix line)) (diff:line-bytes line)
               (diff:line-no-newline? line)))
       (vector->list (diff:hunk-lines hunk))))
(import (console))
