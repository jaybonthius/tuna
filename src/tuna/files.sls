(library (tuna files)
  (export make-folders! read-text-file string-prefix? expand-home)
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
        path)))
