(library (tuna core modules)
  (export
    tuna-module-body
    import-spec-library
    install-module-lookup!
    loaded-modules
    source-module
    run-modules!
    eval-in-module)
  (import (chezscheme) (tuna core changes) (tuna core definitions)
          (only (chez-lang body) form-defined-names))

  (define-record-type found
    (nongenerative)
    (sealed #t)
    (fields source lib?))

  (define-record-type module-state
    (nongenerative)
    (sealed #t)
    (fields imports (mutable loaded?)))

  ;; Only the libraries whose body runs, the #!tuna files, become modules.
  (define found-libraries (make-hashtable equal-hash equal?))
  (define modules (make-hashtable equal-hash equal?))
  (define load-order '())

  (define (module-loaded? name)
    (let ([m (hashtable-ref modules name #f)])
      (and m (module-state-loaded? m))))

  (define (loaded-modules) (reverse load-order))

  (define (source-module path)
    (find (lambda (name)
            (let ([found (hashtable-ref found-libraries name #f)])
              (and found (string=? (found-source found) path))))
          (loaded-modules)))

  (define (import-spec-library spec)
    (cond
      [(not (and (pair? spec) (list? spec))) #f]
      [(memq (car spec) '(only except prefix rename add-prefix drop-prefix alias for library))
       (and (pair? (cdr spec)) (import-spec-library (cadr spec)))]
      [(for-all symbol? spec) spec]
      [(and (pair? (cdr spec)) (for-all symbol? (list-head spec (fx- (length spec) 1))))
       (list-head spec (fx- (length spec) 1))]
      [else #f]))

  (define (lib-library? name)
    (let ([found (hashtable-ref found-libraries name #f)])
      (and found (found-lib? found))))

  ;; (x …) is looked for only in lib/, the plugin x and Tuna's own library,
  ;; in that order, so a plugin cannot supply another plugin's modules.
  ;; Tuna's own names resolve only to Tuna's libraries, so no file in a root
  ;; or the working folder replaces the core. A module named (csv7 …) or
  ;; (r6rs …) would replace Chez's own top-level names of that prefix at the
  ;; REPL, and (init) and (repl) are owners.
  (define (install-module-lookup! own-directories lib-root plugins-root library-root cache-root)
    (define (directory-pair source cache) (cons source (string-append cache-root "/" cache)))
    (let* ([lib (directory-pair lib-root "lib")]
           [library (directory-pair library-root "library")]
           [plugins (if (file-directory? plugins-root)
                        (map (lambda (id)
                               (cons (string->symbol id)
                                     (directory-pair (string-append plugins-root "/" id)
                                                     (string-append "plugins/" id))))
                             (filter (lambda (id) (file-directory? (string-append plugins-root "/" id)))
                                     (directory-list plugins-root)))
                        '())]
           [search-own (library-search-handler)])
      (define (roots name)
        (cond
          [(assq (car name) plugins) => (lambda (plugin) (list lib (cdr plugin) library))]
          [else (list lib library)]))
      (library-directories (append own-directories (list lib) (map cdr plugins) (list library)))
      (library-search-handler
        (lambda (who name directories extensions)
          (cond
            [(memq (car name) '(tuna chez-lang))
             (search-own who name own-directories extensions)]
            [(or (member name '((init) (repl))) (memq (car name) '(csv7 r6rs)))
             (errorf who "a module cannot be named ~s" name)]
            [else
             (let-values ([(source object found?)
                           (default-library-search-handler who name (roots name) extensions)])
               (when source
                 (hashtable-set! found-libraries name
                   (make-found source (string-prefix? (string-append (car lib) "/") source))))
               (values source object found?))])))))

  (define (string-prefix? prefix s)
    (let ([n (string-length prefix)])
      (and (fx<= n (string-length s)) (string=? prefix (substring s 0 n)))))

  ;; Chez runs the bodies of the imports a module refers to before the
  ;; module's own; Tuna runs the others too, so every imported module has
  ;; run, on its own behalf, before the importer's body.
  (define (module-started! name specs)
    (let ([imported (filter (lambda (import) (and import (hashtable-contains? found-libraries import)))
                            (map import-spec-library specs))]
          [lib? (lib-library? name)])
      (run-modules! imported)
      (unless lib?
        (for-each move-imported-lib-module! imported))
      (unless (hashtable-contains? modules name)
        (hashtable-set! modules name (make-module-state imported #f)))
      (hashtable-delete! scope-environments name)
      (rank-module! name lib?)
      (let ([previous (current-owner)])
        (current-owner name)
        previous)))

  (define (run-modules! names)
    (for-each invoke-library (filter (lambda (name) (hashtable-contains? found-libraries name)) names)))

  (define (move-imported-lib-module! name)
    (when (lib-library? name)
      (let ([m (hashtable-ref modules name #f)])
        (when m (for-each move-imported-lib-module! (module-state-imports m))))
      (move-before-importers! name)))

  (define (module-finished! name previous-owner)
    (let ([m (hashtable-ref modules name #f)])
      (unless (module-state-loaded? m)
        (module-state-loaded?-set! m #t)
        (set! load-order (cons name load-order))))
    (module-loaded name)
    (current-owner previous-owner))

  (meta define (import-specs forms)
    (let loop ([forms forms] [specs '()])
      (syntax-case forms ()
        [() (reverse specs)]
        [((b form ...) rest ...)
         (and (identifier? #'b) (free-identifier=? #'b #'begin))
         (loop #'(form ... rest ...) specs)]
        [((i spec ...) rest ...)
         (and (identifier? #'i) (free-identifier=? #'i #'import))
         (loop #'(rest ...) (append (reverse (syntax->datum #'(spec ...))) specs))]
        [(form rest ...) (loop #'(rest ...) specs)])))

  ;; Only Chez's own definition forms written at a module's top level are
  ;; exported here; define-public and the standard library's forms export
  ;; their own names, so a macro built on them needs nothing, and a name a
  ;; macro defines with Chez's forms stays private, as in a Chez module.
  (meta define chez-definition-keywords
    (list #'define-syntax #'define-values #'define-record-type #'define-enumeration
          #'define-condition-type #'define-ftype #'define-structure #'module #'alias
          #'meta #'trace-define #'trace-define-syntax))

  (meta define (chez-definition? form)
    (syntax-case form ()
      [(head . rest)
       (and (identifier? #'head)
            (exists (lambda (keyword) (free-identifier=? #'head keyword)) chez-definition-keywords))]
      [_ #f]))

  (define-syntax module-forms
    (lambda (x)
      (lambda (lookup)
        (syntax-case x ()
          [(_ name previous-owner) #'(module-finished! 'name previous-owner)]
          [(k name previous-owner (b form ...) rest ...)
           (and (identifier? #'b) (free-identifier=? #'b #'begin))
           #'(k name previous-owner form ... rest ...)]
          [(k name previous-owner (d . definition) rest ...)
           (and (identifier? #'d) (free-identifier=? #'d #'define))
           #'(begin (define-public . definition) (k name previous-owner rest ...))]
          [(k name previous-owner form rest ...)
           (chez-definition? #'form)
           (let ([module (syntax->datum #'name)])
             (with-syntax ([(defined ...) (form-defined-names #'form lookup)])
               (with-syntax ([(symbol ...)
                              (map (lambda (id) (datum->syntax id (prefixed-symbol module (syntax->datum id))))
                                   #'(defined ...))])
                 #'(begin form (export (rename (defined symbol) ...)) (k name previous-owner rest ...)))))]
          [(k name previous-owner form rest ...)
           #'(begin form (k name previous-owner rest ...))]))))

  ;; this-module and %scope are captured on purpose, from the keyword the
  ;; loader writes in the module's own context. A form given to %scope takes
  ;; that context, so it sees what the module's top-level code sees; that is
  ;; how eval-in-module works.
  (define-syntax tuna-module-body
    (lambda (x)
      (syntax-case x ()
        [(k name form ...)
         (with-syntax ([this-module (datum->syntax #'k 'this-module)]
                       [%scope (datum->syntax #'k '%scope)]
                       [scope-symbol (datum->syntax #'k (prefixed-symbol (syntax->datum #'name) '%scope))]
                       [specs (datum->syntax #'k (import-specs #'(form ...)))])
           #'(begin
               (implicit-exports #t)
               (define-syntax this-module (syntax-rules () [(_) 'name]))
               (define-property this-module module-property 'name)
               (define-syntax %scope
                 (lambda (y)
                   (syntax-case y ()
                     [(_ e) (datum->syntax #'%scope (syntax->datum #'e))])))
               (export (rename (%scope scope-symbol)))
               (define previous-owner (module-started! 'name 'specs))
               (module-forms name previous-owner form ...)))])))

  ;; Chez never frees an environment, so each module instance has one.
  (define scope-environments (make-hashtable equal-hash equal?))

  (define (scope-environment name scope)
    (or (hashtable-ref scope-environments name #f)
        (let ([env (environment `(only ,name ,scope))])
          (hashtable-set! scope-environments name env)
          env)))

  (define (own-changeable? module name)
    (and (symbol? name)
         (equal? (changeable-symbol-module (prefixed-symbol module name)) module)))

  (define (definition->assignment module form)
    (if (and (pair? form) (eq? (car form) 'define) (pair? (cdr form)))
        (let ([head (cadr form)])
          (cond
            [(and (pair? head) (own-changeable? module (car head)))
             `(set! ,(car head) (lambda ,(cdr head) ,@(cddr form)))]
            [(and (own-changeable? module head) (pair? (cddr form)) (null? (cdddr form)))
             `(set! ,head ,(caddr form))]
            [else form]))
        form))

  (define (eval-in-module form name)
    (unless (module-name? name)
      (assertion-violation 'eval-in-module "not a module name" name))
    (unless (module-loaded? name)
      (assertion-violation 'eval-in-module "not a loaded module" name))
    (let ([scope (prefixed-symbol name '%scope)])
      (as-module name
        (eval (list scope (definition->assignment name form))
              (scope-environment name scope))))))
