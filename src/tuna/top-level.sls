(library (tuna top-level)
  (export
    start-top-level!
    load-configuration!
    eval-top-level
    eval-text
    eval-file)
  (import (chezscheme) (tuna core changes) (tuna core definitions) (tuna core modules)
          (only (tuna plugin-manager) read-configuration-lines! read-configuration-line! read-repl-line!)
          (only (chez-lang body) definition-form? form-defined-names))

  (define home #f)
  (define configuration-file #f)
  (define repl-environment #f)
  (define check-keyword (gensym "check-top-level-form"))

  (define seen-generations (make-hashtable equal-hash equal?))
  (define exporters (make-eq-hashtable))
  (define imported-exports (make-hashtable equal-hash equal?))

  ;; Prefixed names defined at the top level, so that a module load that
  ;; replaces one can say so.
  (define top-level-definitions (make-eq-hashtable))

  (define (start-top-level! home-folder configuration)
    (set! home home-folder)
    (set! configuration-file configuration)
    (set! repl-environment (copy-environment (scheme-environment) #t))
    ;; Chez's exit ends only the thread that calls it, unless that is the
    ;; main thread, and Chez's fork-thread does not give the child the
    ;; owner of the code that forked it.
    (eval '(import (only (tuna core replaced) exit fork-thread)) repl-environment)
    (define-top-level-syntax check-keyword check-top-level-form repl-environment))

  (define (prefixed? symbol)
    (let ([s (symbol->string symbol)])
      (let loop ([i 0])
        (and (fx< i (string-length s))
             (or (char=? (string-ref s i) #\:) (loop (fx+ i 1)))))))

  (define (definition-violation who symbol)
    (let ([module (hashtable-ref exporters symbol #f)])
      (raise
        (condition
          (make-violation)
          (make-who-condition who)
          (make-message-condition
            (if (changeable-symbol? symbol)
                (format "~s is ~s's definition; override it with (set! ~s value)" symbol module symbol)
                (format "~s is ~s's definition and cannot be defined again" symbol module)))))))

  (define (defined-names form lookup)
    (syntax-case form ()
      [(d . rest)
       (and (identifier? #'d) (free-identifier=? #'d #'define-public))
       (form-defined-names #'(define . rest) lookup)]
      [_ (if (definition-form? form lookup) (form-defined-names form lookup) '())]))

  (define (check-definition! form lookup)
    (for-each
      (lambda (id)
        (let ([symbol (syntax->datum id)])
          (when (hashtable-contains? exporters symbol)
            (definition-violation (syntax-case form () [(head . rest) (syntax->datum #'head)]) symbol))
          (when (prefixed? symbol)
            (hashtable-set! top-level-definitions symbol #t))))
      (defined-names form lookup)))

  ;; Chez's set! of an unbound name makes a variable, so a prefixed name set
  ;; before its module loads would silently miss the module. In a mutable
  ;; environment top-level-syntax? holds for every name, so a name defined
  ;; at the top level is known by the definition check. A module imported
  ;; earlier in the same form has not run yet, but its names are bound.
  (define (check-assignment! form lookup)
    (syntax-case form ()
      [(s id v)
       (and (identifier? #'s) (free-identifier=? #'s #'set!) (identifier? #'id)
            (let ([symbol (syntax->datum #'id)])
              (and (prefixed? symbol)
                   (not (hashtable-contains? exporters symbol))
                   (not (changeable-identifier? #'id lookup))
                   (not (hashtable-contains? top-level-definitions symbol))
                   (not (top-level-bound? symbol repl-environment)))))
       (raise
         (condition
           (make-violation)
           (make-who-condition 'set!)
           (make-message-condition
             (format "no loaded module exports ~s" (syntax->datum #'id)))))]
      [_ (void)]))

  ;; Only forms written at the top level are checked: no documented means
  ;; shows what a macro's expansion defines.
  (define (check-top-level-form x)
    (lambda (lookup)
      (syntax-case x ()
        [(k form)
         (syntax-case #'form ()
           [(b sub ...)
            (and (identifier? #'b) (free-identifier=? #'b #'begin))
            #'(begin (k sub) ...)]
           [_ (begin
                (check-definition! #'form lookup)
                (check-assignment! #'form lookup)
                #'form)])])))

  (define (import-module! name)
    (let ([exports (library-exports name)])
      (for-each
        (lambda (symbol)
          (unless (memq symbol exports)
            (shadow! symbol (raising-keyword #'raise-removed symbol name))))
        (hashtable-ref imported-exports name '()))
      (hashtable-set! imported-exports name exports)
      (for-each
        (lambda (symbol)
          (when (hashtable-contains? top-level-definitions symbol)
            (hashtable-delete! top-level-definitions symbol)
            (report-safely
              (condition
                (make-warning)
                (make-who-condition 'import)
                (make-message-condition
                  (format "~s replaces the top-level definition of ~s" name symbol))))))
        exports)
      (eval `(import ,name) repl-environment)
      (for-each (lambda (symbol) (hashtable-set! exporters symbol name)) exports)))

  ;; Chez cannot remove a binding from an environment, so the names of an
  ;; unloaded module, and those a reloaded one no longer exports, are
  ;; replaced by keywords that raise when used.
  (define (raising-keyword raiser symbol name)
    (make-variable-transformer
      (lambda (x)
        (with-syntax ([raiser raiser]
                      [symbol (datum->syntax raiser symbol)]
                      [name (datum->syntax raiser name)])
          #'(raiser 'symbol 'name)))))

  (define (shadow! symbol keyword)
    (hashtable-delete! exporters symbol)
    (define-top-level-syntax symbol keyword repl-environment))

  (define (shadow-module! name)
    (for-each (lambda (symbol) (shadow! symbol (raising-keyword #'raise-unloaded symbol name)))
              (library-exports name)))

  ;; A module loaded again or reloaded is a new instance, which the top
  ;; level imports again.
  (define (sync-modules!)
    (define (sync! name act!)
      (let ([generation (module-generation name)])
        (unless (eqv? generation (hashtable-ref seen-generations name #f))
          (act! name)
          (hashtable-set! seen-generations name generation))))
    (for-each (lambda (name) (sync! name shadow-module!)) (unloaded-modules))
    (for-each (lambda (name) (sync! name import-module!)) (loaded-modules)))

  (define (unwrap x)
    (if (annotation? x) (annotation-stripped x) x))

  (define (top-level-imports form)
    (let ([form (unwrap form)])
      (cond
        [(and (pair? form) (eq? (car form) 'import) (list? form))
         (filter values (map import-spec-library (cdr form)))]
        [(and (pair? form) (eq? (car form) 'use-plugin) (pair? (cdr form)) (symbol? (cadr form)))
         (list (list (cadr form)))]
        [(and (pair? form) (eq? (car form) 'begin) (list? form))
         (apply append (map top-level-imports (cdr form)))]
        [else '()])))

  ;; Chez runs a library's body only when code refers to one of its
  ;; variables; Tuna runs every imported module's body. An unloaded module's
  ;; library has run its body already, so it is loaded again before the
  ;; form is compiled against it. Without inspector information a procedure
  ;; defined in the configuration prints as one typed at the REPL does, with
  ;; no source position.
  (define (eval-top-level form)
    (when (equal? (owner-name (current-owner)) '(repl))
      (read-repl-line! (unwrap form)))
    (call-with-quit-safe-library-lock sync-modules!)
    (call-loading-modules
      (lambda ()
        (let ([imports (top-level-imports form)])
          (load-unloaded-modules! imports)
          (call-with-values
            (lambda ()
              (parameterize ([generate-inspector-information #f])
                (call-with-locked-expansion
                  (lambda () (eval (list check-keyword form) repl-environment)))))
            (lambda results
              (run-modules! imports)
              (apply values results)))))))

  (define (read-annotated-forms path consume)
    (let ([sfd (call-with-port (open-file-input-port path) (lambda (p) (make-source-file-descriptor path p)))])
      (call-with-port (open-input-file path)
        (lambda (p)
          (let loop ([position 0])
            (let-values ([(form end) (get-datum/annotations p sfd position)])
              (unless (eof-object? form)
                (consume form)
                (loop end))))))))

  ;; A read error ends the configuration: after it, where the next form
  ;; starts is unknown.
  (define (load-configuration!)
    (when (file-exists? configuration-file)
      (as-module '(init)
        (call-reporting
          (lambda ()
            (read-configuration-lines!)
            (read-annotated-forms configuration-file
              (lambda (form) (call-reporting (lambda () (eval-top-level form))))))))))

  (define (expand-home path)
    (if (and (fx>= (string-length path) 2) (string=? (substring path 0 2) "~/"))
        (string-append home (substring path 1 (string-length path)))
        path))

  (define (read-all text)
    (let ([p (open-input-string text)])
      (let loop ([forms '()])
        (let ([form (read p)])
          (if (eof-object? form)
              (reverse forms)
              (loop (cons form forms)))))))

  (define eval-text
    (case-lambda
      [(text) (eval-text text #f)]
      [(text path)
       (unless (string? text) (assertion-violation 'eval-text "not a string" text))
       (unless (or (not path) (string? path)) (assertion-violation 'eval-text "not a path" path))
       (check-main-thread 'eval-text)
       (let* ([path (and path (normal-path (expand-home path)))]
              [module (and path (path-module 'eval-text path))]
              [eval-form (cond
                           [module (lambda (form) (eval-in-module form module))]
                           [(and path (string=? path configuration-file))
                            (lambda (form)
                              (read-configuration-line! form)
                              (as-module '(init) (eval-top-level form)))]
                           [else (lambda (form) (as-module '(repl) (eval-top-level form)))])])
         (let loop ([forms (read-all text)] [results (list (void))])
           (if (null? forms)
               (apply values results)
               (loop (cdr forms) (call-with-values (lambda () (eval-form (car forms))) list)))))]))

  (define (eval-file path)
    (unless (string? path) (assertion-violation 'eval-file "not a path" path))
    (check-main-thread 'eval-file)
    (let* ([path (normal-path (expand-home path))] [module (path-module 'eval-file path)])
      (cond
        [module
         (if (module-loaded? module)
             (reload-module! module)
             (load-module! module))
         (void)]
        [(string=? path configuration-file)
         (take-back-changes! '(init) '())
         (load-configuration!)]
        [else
         (as-module '(repl) (read-annotated-forms path eval-top-level))]))))
