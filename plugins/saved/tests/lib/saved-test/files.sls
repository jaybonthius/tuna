#!tuna
;; saved offers no wait until its writer is done, so tests wait for the
;; file to hold what they set.
(import (test-runner))

(define (root) (string-append (getenv "HOME") "/.local/share/tuna/saved"))

(define (file . parts) (apply string-append (root) (map (lambda (part) (string-append "/" part)) parts)))

(define (stored path)
  (and (file-exists? path) (guard (c [#t 'unreadable]) (call-with-input-file path read))))

(define (wait-for-stored! path value)
  (test-runner:wait-until (lambda () (equal? (stored path) value))))

(define (write-text! path text)
  (let make ([folder (path-parent path)])
    (unless (file-directory? folder) (make (path-parent folder)) (mkdir folder)))
  (call-with-output-file path (lambda (p) (put-string p text)) 'replace))

(define (escaped path)
  (apply string-append
    (map (lambda (c) (case c [(#\/) "%2F"] [(#\%) "%25"] [else (string c)])) (string->list path))))
