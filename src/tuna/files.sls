(library (tuna files)
  (export make-folders! read-text-file)
  (import (chezscheme))

  ;; Another thread, or another Tuna, may make the same folder at the same
  ;; moment.
  (define (make-folders! path)
    (unless (or (string=? path "") (file-directory? path))
      (make-folders! (path-parent path))
      (guard (c [(file-directory? path) (void)])
        (mkdir path))))

  (define (read-text-file path)
    (call-with-port
      (open-file-input-port path (file-options) (buffer-mode block)
        (make-transcoder (utf-8-codec) (eol-style lf) (error-handling-mode replace)))
      (lambda (p)
        (let ([s (get-string-all p)])
          (if (eof-object? s) "" s))))))
