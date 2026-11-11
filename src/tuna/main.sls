;;; A library, so that both bin/tuna.sps and the executable's boot file can
;;; run the program.
(library (tuna main)
  (export main)
  (import (chezscheme) (chez-lang loader) (tuna version) (tuna core changes)
          (tuna core modules) (except (tuna core main-thread) exit) (tuna top-level)
          (only (tuna plugin-manager) start-plugins! plugin-root install-missing-plugin! plugin-roots
                module-plugin-source)
          (only (tuna storage) start-storage!) (only (tuna saved) finish-saved-data!))

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
       (run-main-loop)]
      [(equal? arguments '("--version"))
       (printf "tuna ~a\n" tuna-version)
       (exit 0)]
      [else
       (fprintf (console-error-port) "tuna: unknown arguments ~s\nusage: tuna [--version]\n"
         arguments)
       (exit 2)]))

  (define (start home library own-directories)
    (let* ([configuration (string-append home "/.config/tuna")]
           [lib (string-append configuration "/lib")])
      (compile-file-message #f)
      (optimize-level 2)
      (start-plugins! home (string-append configuration "/init.ss") lib library
        (string-append home "/.local/share/tuna/plugins"))
      (start-storage! (string-append home "/.local/share/tuna/saved") module-plugin-source)
      (install-module-lookup! own-directories lib library (string-append home "/.cache/tuna")
        plugin-root install-missing-plugin! plugin-roots)
      (install-loader!)
      ;; Modules are compiled within top-level forms, which are evaluated
      ;; without inspector information. Modules keep each procedure's
      ;; source for backtraces but not the rest of inspector information,
      ;; which makes every module object slower to load.
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
                               [generate-procedure-source-information #t])
                  (compile-library source object)))))))
      (start-top-level! home (string-append configuration "/init.ss"))
      (install-exit-handler!)
      (post-task! load-configuration! (find-owner '(init)) (lambda () (fork-thread read-console)))))

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
              (finish-saved-data!))
            (fresh-line (current-output-port))
            (flush-output-port (current-output-port)))
          (apply exit-process exit-arguments)))))

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

  ;; Chez's console input and output are one port under one mutex, which a
  ;; read holds while it waits, so the main thread could not write until
  ;; the next line came. The port is kept for the life of the process:
  ;; collecting it would close standard input.
  (define console-input
    (transcoded-port (standard-input-port (buffer-mode block)) (native-transcoder)))

  (define (next-input)
    (guard (c [#t (lambda () (raise c))])
      (let ([form (read console-input)])
        (if (eof-object? form)
            form
            (lambda () (call-with-values (lambda () (eval-top-level form)) print-values))))))

  ;; Each form runs to its end, pauses included, before the next is read,
  ;; as at Chez's own REPL.
  (define (read-console)
    (let ([m (make-mutex)] [finished (make-condition)] [finished? #f])
      (let loop ()
        (let ([input (next-input)])
          (cond
            [(eof-object? input) (post-task! exit (find-owner '(repl)) #f)]
            [else
             (with-mutex m (set! finished? #f))
             (post-task! input (find-owner '(repl))
               (lambda () (with-mutex m (set! finished? #t) (condition-signal finished))))
             (with-mutex m
               (let wait ()
                 (unless finished?
                   (condition-wait finished m)
                   (wait))))
             (loop)]))))))
