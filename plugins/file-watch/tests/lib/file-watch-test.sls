#!tuna
(import (test-runner) (options) (file-watch))

(define (home name) (string-append (getenv "HOME") "/" name))

(define (write! name text)
  (call-with-port (open-file-output-port (home name) (file-options no-fail) (buffer-mode block) (native-transcoder))
    (lambda (p) (put-string p text))))

(define (write-by-rename! name text)
  (write! (string-append name ".tmp") text)
  (rename-file (home (string-append name ".tmp")) (home name)))

(define (folder! name) (unless (file-exists? (home name)) (mkdir (home name))))

(define %calls '())

(define (recorder entry kind) (set! %calls (cons (list entry kind) %calls)))

(define (calls) (reverse %calls))

(define (take-calls!) (let ([c (calls)]) (set! %calls '()) c))

(define (wait-for-calls n) (test-runner:wait-until (lambda () (>= (length %calls) n))))

;; The job reports events in the order the kernel queued them and the
;; handlers run in that order, so once the call for a marker written now
;; has come, every call for the events made before it has come.
(define (mark!)
  (let* ([seen #f] [w (file-watch:watch! (home "mark") (lambda (entry kind) (set! seen #t)))])
    (write! "mark" "mark")
    (test-runner:wait-until (lambda () seen))
    (file-watch:unwatch! w)))

(options:set! file-watch:delay 0.01)
