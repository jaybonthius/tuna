;;; A library, so that both bin/tuna.sps and the executable's boot file can
;;; run the program.
(library (tuna main)
  (export main)
  (import (chezscheme) (chez-lang loader) (tuna version) (tuna core changes)
          (only (tuna core definitions) call-reporting)
          (tuna core modules) (tuna top-level))

  ;; Exit status 2 marks a usage error, as in most command-line programs.
  (define (main program arguments own-directories)
    (cond
      [(null? arguments)
       (let ([home (getenv "HOME")])
         (unless home
           (fprintf (console-error-port) "tuna: HOME is not set\n")
           (exit 1))
         (start (normal-path home)
           (normal-path (or (getenv "TUNA_LIBRARY") (path-build (path-parent program) "plugins")))
           own-directories))
       (as-module '(repl) (console-repl))
       (exit 0)]
      [(equal? arguments '("--version"))
       (printf "tuna ~a\n" tuna-version)
       (exit 0)]
      [else
       (fprintf (console-error-port) "tuna: unknown arguments ~s\nusage: tuna [--version]\n"
         arguments)
       (exit 2)]))

  (define (start home library own-directories)
    (let ([configuration (string-append home "/.config/tuna")])
      (compile-file-message #f)
      (optimize-level 2)
      (install-module-lookup! own-directories
        (string-append configuration "/lib")
        (string-append home "/.local/share/tuna/plugins")
        library
        (string-append home "/.cache/tuna"))
      (install-loader!)
      ;; Top-level forms are evaluated without inspector information, and
      ;; the modules they import are compiled within them; modules keep it
      ;; for the debugger.
      (compile-library-handler
        (let ([compile-library (compile-library-handler)])
          (lambda (source object)
            (parameterize ([generate-inspector-information #t])
              (compile-library source object)))))
      (start-top-level! home (string-append configuration "/init.ss"))
      (load-configuration!)))

  (define (print-values . results)
    (let ([out (current-output-port)])
      (for-each
        (lambda (v)
          (unless (eq? v (void))
            (fresh-line out)
            (write v out)
            (newline out)))
        results)
      (fresh-line out)
      (flush-output-port out)))

  (define (console-repl)
    (unless (eof-object?
              (call-reporting
                (lambda ()
                  (let ([form (read)])
                    (unless (eof-object? form)
                      (call-with-values (lambda () (eval-top-level form)) print-values))
                    form))))
      (console-repl))))
