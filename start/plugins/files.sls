(library (plugins files)
  (export make-folders! read-text-file string-prefix? expand-home normal-path import-spec-library)
  (import (chezscheme))

  ;; Another thread, or another Tuna, may make the same folder at the same
  ;; moment.
  (define (make-folders! path)
    (unless (or (string=? path "") (file-directory? path))
      (make-folders! (path-parent path))
      (guard (c [(and (i/o-error? c) (file-directory? path)) (void)])
        (mkdir path))))

  (define (read-text-file path)
    (call-with-port
      (open-file-input-port path (file-options) (buffer-mode block)
        (make-transcoder (utf-8-codec) (eol-style lf) (error-handling-mode replace)))
      (lambda (p)
        (let ([s (get-string-all p)])
          (if (eof-object? s) "" s)))))

  (define (string-prefix? prefix s)
    (let ([n (string-length prefix)])
      (and (fx<= n (string-length s)) (string=? prefix (substring s 0 n)))))

  (define (expand-home path home)
    (if (string-prefix? "~/" path)
        (string-append home (substring path 1 (string-length path)))
        path))

  (define (split-path path)
    (let loop ([chars (string->list path)] [part '()] [parts '()])
      (cond
        [(null? chars) (reverse (cons (list->string (reverse part)) parts))]
        [(char=? (car chars) #\/) (loop (cdr chars) '() (cons (list->string (reverse part)) parts))]
        [else (loop (cdr chars) (cons (car chars) part) parts)])))

  ;; Paths are compared as strings with the paths the lookup finds, which
  ;; are absolute and have no "." or ".." parts and no repeated "/".
  (define (normal-path path)
    (let loop ([parts (split-path (if (path-absolute? path)
                                      path
                                      (string-append (current-directory) "/" path)))]
               [kept '()])
      (cond
        [(null? parts)
         (if (null? kept)
             "/"
             (call-with-string-output-port
               (lambda (p) (for-each (lambda (part) (put-char p #\/) (put-string p part)) (reverse kept)))))]
        [(member (car parts) '("" ".")) (loop (cdr parts) kept)]
        [(string=? (car parts) "..") (loop (cdr parts) (if (null? kept) kept (cdr kept)))]
        [else (loop (cdr parts) (cons (car parts) kept))])))

  (define (import-spec-library spec)
    (cond
      [(not (and (pair? spec) (list? spec))) #f]
      [(memq (car spec) '(only except prefix rename add-prefix drop-prefix alias for library))
       (and (pair? (cdr spec)) (import-spec-library (cadr spec)))]
      [(for-all symbol? spec) spec]
      [(and (pair? (cdr spec)) (for-all symbol? (list-head spec (fx- (length spec) 1))))
       (list-head spec (fx- (length spec) 1))]
      [else #f])))
