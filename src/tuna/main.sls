;;; A library, so that both bin/tuna.sps and the executable's boot file can
;;; run the program.
(library (tuna main)
  (export main)
  (import (chezscheme) (chez-lang loader) (tuna version) (tuna core changes)
          (tuna core modules) (except (tuna core main-thread) exit) (tuna top-level)
          (only (tuna plugin-manager) start-plugins! module-plugin-source)
          (only (tuna storage) start-storage! wait-for-saved-files!))

  ;; Tuna's own options are read only at the start of the command line, so
  ;; any other command line, such as a file to open, is the plugins'.
  (define (main program arguments own-directories)
    (cond
      [(equal? arguments '("--version"))
       (printf "tuna ~a\n" tuna-version)
       (exit 0)]
      ;; A plugin's build runs where no scheme program may be installed,
      ;; and a library's makefile runs $(SCHEME) -q --script.
      [(script-arguments arguments) => (lambda (script) (apply (scheme-script) script))]
      [else
       (command-line (cons program arguments))
       (command-line-arguments arguments)
       (let ([home (getenv "HOME")])
         (unless home
           (fprintf (console-error-port) "tuna: HOME is not set\n")
           (exit 1))
         (start program (normal-path home)
           (normal-path (or (getenv "TUNA_LIBRARY") (path-build (path-parent program) "plugins")))
           (normal-path (path-build (path-parent program) "libraries"))
           own-directories))
       (run-main-loop)]))

  (define (script-arguments arguments)
    (let ([arguments (if (and (pair? arguments) (string=? (car arguments) "-q")) (cdr arguments) arguments)])
      (and (pair? arguments) (string=? (car arguments) "--script") (pair? (cdr arguments))
           (cdr arguments))))

  (define (start program home library libraries own-directories)
    (let* ([configuration (string-append home "/.config/tuna")]
           [lib (string-append configuration "/lib")])
      (compile-file-message #f)
      (optimize-level 2)
      (start-plugins! program home (string-append configuration "/init.ss") lib library
        (string-append home "/.local/share/tuna/plugins") libraries
        (string-append home "/.local/share/tuna/libraries"))
      (start-storage! (string-append home "/.local/share/tuna/saved") module-plugin-source)
      (install-module-lookup! own-directories lib library (string-append home "/.cache/tuna"))
      (install-loader!)
      ;; Modules are compiled within top-level forms, which are evaluated
      ;; without inspector information. Modules keep each procedure's
      ;; source for backtraces but not the rest of inspector information,
      ;; which makes every module object slower to load. The compile
      ;; settings are thread parameters that code on the main thread may
      ;; set; a module compiled unsafe could read past a vector's end, and
      ;; one compiled without traps could not be quit.
      (compile-library-handler
        (let ([compile-library (compile-library-handler)])
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
                               [generate-interrupt-trap #t])
                  (compile-library source object)))))))
      (start-top-level! home (string-append configuration "/init.ss"))
      (install-exit-handler!)
      (post-task! load-configuration! (find-owner '(init)))))

  ;; Chez reports a definition after an expression on Tuna's expansion of
  ;; the definition, which has no position, so the file stands in as the
  ;; error's who. An error that has a who already, such as one from a file
  ;; compiled for this one, keeps it.
  (define (positionless-syntax-error? c)
    (and (syntax-violation? c)
         (not (who-condition? c))
         (not (syntax->annotation (syntax-violation-form c)))
         (not (syntax->annotation (syntax-violation-subform c)))))

  ;; Unloading runs every module's unload actions, for what Tuna cannot
  ;; undo itself, such as a process a module started. An exit called while
  ;; unloading, as from an unload action, ends the process with the first
  ;; exit's status.
  (define (install-exit-handler!)
    (let ([exit-process (exit-handler)] [exit-arguments #f])
      (exit-handler
        (lambda arguments
          (unless exit-arguments
            (set! exit-arguments arguments)
            (close-queue!)
            (with-quits-allowed #f
              (for-each (lambda (owner) (take-back-changes! owner '())) '((repl) (init)))
              (unload-all-modules!)
              (run-queued!)
              (wait-for-saved-files!))
            (fresh-line (current-output-port))
            (flush-output-port (current-output-port)))
          (apply exit-process exit-arguments))))))
