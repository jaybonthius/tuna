#!tuna
(import (test-runner) (files))

(define (home-path name) (string-append (getenv "HOME") "/" name))

(define (write-text! path text)
  (call-with-port (open-file-output-port path (file-options no-fail))
    (lambda (p) (put-bytevector p (string->utf8 text)))))

(define (read-text path)
  (let ([bytes (call-with-port (open-file-input-port path) get-bytevector-all)])
    (if (eof-object? bytes) "" (utf8->string bytes))))

;; undo-log names a folder of its own under this one, and makes it with
;; its first log, so a fresh home holds at most one.
(define (log-of path)
  (let ([root (home-path ".local/share/tuna/undo-log")])
    (and (file-directory? root)
         (let ([names (directory-list root)])
           (cond
             [(null? names) #f]
             [(null? (cdr names)) (string-append root "/" (car names) path ".ss")]
             [else (errorf 'log-of "~s holds more than one log folder: ~s" root names)])))))

(define (logged? path)
  (let ([file (log-of path)])
    (and file (file-exists? file))))

(define (records path)
  (if (logged? path)
      (call-with-input-file (log-of path)
        (lambda (p)
          (let loop ([acc '()])
            (let ([d (read p)])
              (if (eof-object? d) (reverse acc) (loop (cons d acc)))))))
      '()))

(define (kinds path) (map car (records path)))

;; The log is written by a thread of its own, so a check waits for the
;; number of records it expects.
(define (logged-kinds path n)
  (test-runner:wait-until (lambda () (>= (length (records path)) n)))
  (kinds path))

(define (log-size path)
  (if (logged? path) (call-with-port (open-file-input-port (log-of path)) port-length) 0))

(define (file-mode path) (number->string (get-mode path) 8))
