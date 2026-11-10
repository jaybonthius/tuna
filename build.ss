(unless (and (string=? (scheme-version) "Chez Scheme Version 10.4.1")
             (threaded?))
  (errorf 'build "need threaded Chez Scheme 10.4.1, not ~a (~a)"
    (scheme-version) (if (threaded?) "threaded" "non-threaded")))

(define object-root "build/obj")
(define source-roots '("src" "lib/chez-lang/src"))
(library-directories
  (map (lambda (root) (cons root (string-append object-root "/" root)))
       source-roots))
(compile-imported-libraries #t)
(optimize-level 2)
;; Keeps the frame of a failing call, so a backtrace or a test failure
;; points at the faulting expression.
(debug-level 2)
(generate-inspector-information #t)
(compile-file-message #f)

(define compiled 0)
(define problems 0)

(define (report c)
  (set! problems (+ problems 1))
  (display-condition c (console-error-port))
  (newline (console-error-port)))

;; Chez runs its source optimizer twice by default, so one warning can be
;; raised twice; report each distinct message once.
(define seen-warnings (make-hashtable string-hash string=?))

;; An object compiled with a warning is still written; deleting it makes
;; the next build compile it again and fail again until the source is fixed.
(define (compiling src obj compile)
  (set! compiled (+ compiled 1))
  (printf "compiling ~a\n" src)
  (let ([problems-before problems] [finished? #f])
    (dynamic-wind
      void
      (lambda () (compile src obj) (set! finished? #t))
      (lambda ()
        (unless (and finished? (= problems problems-before))
          (when (file-exists? obj) (delete-file obj)))))))

(compile-library-handler (lambda (src obj) (compiling src obj compile-library)))
(compile-program-handler (lambda (src obj) (compiling src obj compile-program)))

;; Chez reports wrong argument counts only as warnings, so warnings fail
;; the build. A guard would stop the compile at the first warning;
;; returning from the handler lets it continue and report every warning.
(define (with-warnings-as-errors thunk)
  (guard (c [#t (report c)])
    (with-exception-handler
      (lambda (c)
        (if (warning? c)
            (let ([text (call-with-string-output-port
                          (lambda (p) (display-condition c p)))])
              (unless (hashtable-ref seen-warnings text #f)
                (hashtable-set! seen-warnings text #t)
                (report c)))
            (raise-continuable c)))
      thunk)))

(define (ensure-parent-directory file)
  (let loop ([d (path-parent file)])
    (unless (or (string=? d "") (file-directory? d))
      (loop (path-parent d))
      (mkdir d))))

(define (find-files dir extension)
  (if (file-directory? dir)
      (let walk ([dir dir])
        (apply append
          (map (lambda (f)
                 (let ([p (string-append dir "/" f)])
                   (cond
                     [(file-directory? p) (walk p)]
                     [(equal? (path-extension p) extension) (list p)]
                     [else '()])))
               (sort string<? (directory-list dir)))))
      '()))

(define (object-file src)
  (string-append object-root "/" (path-root src) ".so"))

;; An import adds a library's own directory to source-directories, so its
;; included files resolve; a library compiled here directly needs the same.
(define (build-each maybe-compile sources)
  (for-each
    (lambda (src)
      (let ([obj (object-file src)])
        (ensure-parent-directory obj)
        (parameterize ([source-directories (cons (path-parent src) (source-directories))])
          (with-warnings-as-errors (lambda () (maybe-compile src obj))))))
    sources))

(build-each maybe-compile-library
  (apply append (map (lambda (root) (find-files root "sls")) source-roots)))

;; Test programs are compiled here too, so they get the same debug
;; information and their warnings fail the build. Not recursive: a
;; transcript's folder holds the files of a home, which the program under
;; test compiles, not the build.
(build-each maybe-compile-program
  (cons "bin/tuna.sps"
    (map (lambda (f) (string-append "tests/" f))
         (filter (lambda (f) (equal? (path-extension f) "sps"))
                 (sort string<? (directory-list "tests"))))))

(printf "build: ~a compiled, ~a problems\n" compiled problems)
(exit (if (= problems 0) 0 1))
