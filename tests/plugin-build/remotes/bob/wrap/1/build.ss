(define (run command)
  (unless (zero? (system command))
    (errorf 'build "~a failed" command)))

(unless (file-directory? "build") (mkdir "build"))
(unless (file-directory? "src/build") (mkdir "src/build"))
(run "cc -O2 -shared -fPIC -o build/libwrap.so vendor/cadd/add.c")
(with-output-to-file "src/build/paths.ss"
  (lambda ()
    (write `(define shared-object ,(string-append (current-directory) "/build/libwrap.so"))))
  'replace)
(with-output-to-file "build/facts.ss"
  (lambda ()
    (write (list (scheme-version) (command-line-arguments) (getenv "GIT_TERMINAL_PROMPT")
                 (eof-object? (read-char)) (current-directory))))
  'replace)
(display "built\n")
