;;; A library, so that both bin/tuna.sps and the executable's boot file can
;;; run the program.
(library (tuna main)
  (export main)
  (import (except (chezscheme) exit) (prefix (only (chezscheme) exit) chez-) (lang loader)
          (tuna version) (tuna core kernel) (tuna core modules))

  ;; The kernel reads only these; the rest of the command line is the
  ;; plugins'.
  (define (main program arguments own-directories)
    (cond
      [(equal? arguments '("--version"))
       (printf "tuna ~a\n" tuna-version)
       (chez-exit 0)]
      ;; A plugin's build runs where no scheme program may be installed,
      ;; and a library's makefile runs $(SCHEME) -q --script.
      [(script-arguments arguments) => (lambda (script) (apply (scheme-script) script))]
      [else
       (let-values ([(start-roots arguments) (start-roots program arguments)])
         (command-line (cons program arguments))
         (command-line-arguments arguments)
         (start start-roots own-directories))
       (run-main-loop)]))

  (define (script-arguments arguments)
    (let ([arguments (if (and (pair? arguments) (string=? (car arguments) "-q")) (cdr arguments) arguments)])
      (and (pair? arguments) (string=? (car arguments) "--script") (pair? (cdr arguments))
           (cdr arguments))))

  (define (string-prefix? prefix s)
    (let ([n (string-length prefix)])
      (and (fx<= n (string-length s)) (string=? prefix (substring s 0 n)))))

  (define (absolute path)
    (if (path-absolute? path) path (string-append (current-directory) "/" path)))

  (define (cache-root)
    (let ([cache (getenv "XDG_CACHE_HOME")] [home (getenv "HOME")])
      (cond
        [(and cache (> (string-length cache) 0)) (string-append (absolute cache) "/tuna")]
        [home (string-append home "/.cache/tuna")]
        [else (fprintf (console-error-port) "tuna: HOME is not set\n") (chez-exit 1)])))

  ;; A start folder may hold start.sls alone; the install's folder still
  ;; gives what it does not, such as the plugin manager. Each start folder
  ;; compiles to objects of its own: Chez loads an object newer than its
  ;; source, so one shared folder would run whichever start module compiled
  ;; last.
  (define (start-roots program arguments)
    (let* ([flag "--start="]
           [install (string-append (path-parent program) "/start")]
           [given? (and (pair? arguments) (string-prefix? flag (car arguments)))]
           [folders (if given?
                        (list (absolute (substring (car arguments) (string-length flag) (string-length (car arguments))))
                              install)
                        (list install))]
           [cache (cache-root)])
      (values (map (lambda (folder) (cons folder (string-append cache "/start" folder))) folders)
              (if given? (cdr arguments) arguments))))

  (define (start start-roots own-directories)
    (compile-file-message #f)
    (optimize-level 2)
    (install-module-lookup! own-directories start-roots)
    (install-loader!)
    ;; Modules are compiled within top-level forms, which are evaluated
    ;; without inspector information. Modules keep each procedure's
    ;; source for backtraces but not the rest of inspector information,
    ;; which makes every module object slower to load. The compile
    ;; settings are thread parameters that code on the main thread may
    ;; set; a module compiled unsafe could read past a vector's end, and
    ;; one compiled without traps could not be stopped. A library's file is
    ;; expanded in the interaction environment, the top level, where a user
    ;; may have defined library or import as a variable, so it is expanded
    ;; in a top level of Chez's own.
    (compile-library-handler
      (let ([compile-library (compile-library-handler)]
            [chez-top-level (copy-environment (scheme-environment) #t)])
        (lambda (source object)
          (with-exception-handler
            (lambda (c)
              (if (positionless-syntax-error? c)
                  (raise (condition (make-who-condition source) c))
                  (raise-continuable c)))
            (lambda ()
              (parameterize ([generate-inspector-information #f]
                             [generate-procedure-source-information #t]
                             [optimize-level 2]
                             [enable-unsafe-application #f]
                             [enable-unsafe-variable-reference #f]
                             [generate-interrupt-trap #t]
                             [interaction-environment chez-top-level])
                (compile-library source object)))))))
    (start-top-level!)
    (install-exit-runner!)
    ;; Imported at the top level, so the top level gets its compile-time
    ;; information as well as its body. Nothing would ever run after a
    ;; start module that failed to load.
    (spawn-kernel-task
      (lambda (restore)
        (guard (c [#t (report-safely c) (chez-exit 1)])
          (parameterize ([generate-inspector-information #f])
            (eval '(import (start)) (interaction-environment)))))))

  ;; Chez reports a definition after an expression on Tuna's expansion of
  ;; the definition, which has no position, so the file stands in as the
  ;; error's who. An error that has a who already, such as one from a file
  ;; compiled for this one, keeps it.
  (define (positionless-syntax-error? c)
    (and (syntax-violation? c)
         (not (who-condition? c))
         (not (syntax->annotation (syntax-violation-form c)))
         (not (syntax->annotation (syntax-violation-subform c))))))
