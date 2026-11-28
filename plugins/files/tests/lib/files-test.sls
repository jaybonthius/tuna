#!tuna
(import (options) (ask) (jobs) (document) (buffers))

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

(define %link (begin (load-shared-object #f) (foreign-procedure "link" (string string) int)))

(define %symlink (foreign-procedure "symlink" (string string) int))

(define %stat (foreign-procedure "stat" (string uptr) int))

(define (link! from to) (%link (expand from) (expand to)))

(define (symlink! target link) (%symlink (expand target) (expand link)))

;; st_nlink is at offset 16 of struct stat on x86-64 Linux.
(define (link-count path)
  (let ([buffer (foreign-alloc 144)])
    (%stat (expand path) buffer)
    (let ([n (foreign-ref 'unsigned-64 buffer 16)])
      (foreign-free buffer)
      n)))

(define (mode path) (get-mode (expand path)))

(define (set-mode! path mode) (chmod (expand path) mode))

(define (symlink? path) (file-symbolic-link? (expand path)))

(define (folder! path) (mkdir (expand path)))

(define (folder-files path) (list-sort string<? (directory-list (expand path))))

(define (exists? path) (file-exists? (expand path) #f))

(define (fnv bytes)
  (let loop ([i 0] [h 2166136261])
    (if (= i (bytevector-length bytes))
        h
        (loop (+ i 1) (bitwise-and (* (bitwise-xor h (bytevector-u8-ref bytes i)) 16777619) #xFFFFFFFF)))))

(define (text b) (document:text (buffers:document b)))

(define %asked '())

(define (answer reply) (lambda (question . rest) (set! %asked (cons question %asked)) reply))

(define (replies . answers)
  (lambda (question . rest)
    (set! %asked (cons question %asked))
    (let ([a (car answers)]) (set! answers (cdr answers)) a)))

(define (questions) (let ([q (reverse %asked)]) (set! %asked '()) q))

(define %said '())

(define (take-said!) (let ([s (reverse %said)]) (set! %said '()) s))

;; A user may type at any time, so also between the start of a reload's
;; read and its result, which a job delivers in a later task. The job is
;; known by the text it reads against, since this library imports no files,
;; which a test unloads.
(define (typing-during-read buffer text thunk)
  (let ([typed? #f])
    (define (type next worker input . rest)
      (let ([job (apply next worker input rest)])
        (when (and (not typed?) (pair? input) (eq? (cdr input) (buffers:document buffer)))
          (set! typed? #t)
          (buffers:replace! buffer 1 1 text))
        job))
    (advice-add! jobs:start type)
    (call-with-values thunk
      (lambda results
        (advice-remove! jobs:start type)
        (apply values results)))))

;; ask's own writer reports each message as a warning, which would fail
;; the test file; the tests read the messages instead.
(options:set! ask:message-writer (lambda (text) (set! %said (cons text %said))))
