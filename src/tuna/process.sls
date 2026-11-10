(library (tuna process)
  (export run-program)
  (import (chezscheme))

  ;; Chez's system keeps the exit status, which open-process-ports loses to
  ;; the collector, and it lets other threads collect while it waits; glibc
  ;; spawns the shell without copying Tuna's heap. The output goes through
  ;; a file because system gives the child no pipe.
  (define (run-program program arguments)
    (unless (string? program)
      (assertion-violation 'run-program "not a string" program))
    (unless (and (list? arguments) (for-all string? arguments))
      (assertion-violation 'run-program "not a list of strings" arguments))
    (let ([output (output-path)])
      (dynamic-wind
        void
        (lambda ()
          (let ([status (system (format "exec ~a~{ ~a~} </dev/null >~a 2>&1"
                                  (shell-quote program) (map shell-quote arguments)
                                  (shell-quote output)))])
            (values status (read-output output))))
        (lambda () (delete-file output #f)))))

  ;; A folder of Tuna's own, so no other user can place a file or a link
  ;; under the name the shell writes to.
  (define (output-path)
    (let ([folder (string-append (or (getenv "HOME") (assertion-violation 'run-program "HOME is not set"))
                                 "/.cache/tuna")])
      (make-folders! folder)
      (format "~a/~a.out" folder (gensym->unique-string (gensym)))))

  ;; Another thread may make the same folder at the same moment.
  (define (make-folders! path)
    (unless (file-directory? path)
      (make-folders! (path-parent path))
      (guard (c [(file-directory? path) (void)])
        (mkdir path))))

  (define (shell-quote s)
    (call-with-string-output-port
      (lambda (p)
        (put-char p #\')
        (string-for-each
          (lambda (c) (if (char=? c #\') (put-string p "'\\''") (put-char p c)))
          s)
        (put-char p #\'))))

  (define (read-output path)
    (if (file-exists? path)
        (call-with-port
          (open-file-input-port path (file-options) (buffer-mode block)
            (make-transcoder (utf-8-codec) (eol-style lf) (error-handling-mode replace)))
          (lambda (p)
            (let ([s (get-string-all p)])
              (if (eof-object? s) "" s))))
        "")))
