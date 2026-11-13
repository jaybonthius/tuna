(library (tuna core modules)
  (export
    tuna-module-body
    check-import
    import-spec-library
    install-module-lookup!
    set-library-roots!
    found-library-source
    found-libraries-under
    loaded-libraries-under
    module-exists?
    module-loaded?
    loaded-modules
    unloaded-modules
    module-generation
    normal-path
    path-module
    call-loading-modules
    load-unloaded-modules!
    run-modules!
    load-module!
    unload-module!
    unload-all-modules!
    reload-module!
    running-module-body
    call-with-locked-expansion
    call-with-quit-safe-library-lock
    on-unload
    add-module-loaded-handler!
    add-module-unloaded-handler!
    take-back-changes!
    eval-in-module)
  (import (chezscheme) (tuna core changes) (tuna core definitions) (tuna core conditions)
          (prefix (only (chezscheme) exit fork-thread dynamic-wind with-mutex sleep set-timer
                        timer-interrupt-handler make-engine)
                  chez:)
          (prefix (only (rnrs) exit dynamic-wind) rnrs:)
          (only (chez-lang body) form-defined-names)
          (only (chez-lang language) call-with-library-lock)
          (only (chez-lang reload) reload-library)
          (only (tuna files) string-prefix?))

  (define lib-prefix #f)
  (define source-roots (lambda () '()))
  (define find-module (lambda (who name extensions) (values #f #f #f)))
  (define set-roots! (lambda (roots) (void)))

  ;; A module is stale once its library instance has run and the module has
  ;; been unloaded: Chez runs a library's body once per instance, so running
  ;; it again needs a new instance. The generation counts the instances and
  ;; unloads, so the top level can tell when to import or shadow its names.
  ;; Chez never frees an environment, so each instance makes one, for
  ;; eval-in-module, when first needed.
  (define-record-type module-state
    (nongenerative)
    (sealed #t)
    (fields (mutable imports) (mutable loaded?) (mutable stale?) (mutable generation)
            (mutable environment) (mutable running-object))
    (protocol
      (lambda (new)
        (lambda (imports stale? generation)
          (new imports #f stale? generation #f #f)))))

  ;; Only the libraries whose body runs, the #!tuna files, become modules.
  (define found-libraries (make-hashtable equal-hash equal?))
  (define modules (make-hashtable equal-hash equal?))
  (define load-order '())

  (define running-bodies '())

  (define (running-module-body)
    (and (pair? running-bodies) (car running-bodies)))

  (define (module-loaded? name)
    (let ([m (hashtable-ref modules name #f)])
      (and m (module-state-loaded? m))))

  (define (module-stale? name)
    (let ([m (hashtable-ref modules name #f)])
      (and m (module-state-stale? m))))

  (define (loaded-modules) (reverse load-order))

  (define (unloaded-modules)
    (filter module-stale? (vector->list (hashtable-keys modules))))

  (define (module-generation name)
    (let ([m (hashtable-ref modules name #f)])
      (if m (module-state-generation m) 0)))

  (define (loaded-importers name)
    (filter (lambda (importer)
              (member name (module-state-imports (hashtable-ref modules importer #f))))
            load-order))

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
    (let ([source (hashtable-ref found-libraries name #f)])
      (and source (string-prefix? lib-prefix source))))

  ;; A module named (csv7 …) or (r6rs …) would replace Chez's own top-level
  ;; names of that prefix at the REPL, and (init) and (repl) are owners.
  (define (refused-module-name? name)
    (or (member name '((init) (repl))) (memq (car name) '(csv7 r6rs))))

  ;; lib/ is searched first, so the user's own module wins, and Tuna's own
  ;; library last, so an installed plugin replaces Tuna's of its name.
  ;; Tuna's own names resolve only to Tuna's libraries, so no file in a root
  ;; or the working folder replaces the core.
  (define (install-module-lookup! own-directories lib-root library-root cache-root)
    (define (directory-pair source cache) (cons source (string-append cache-root "/" cache)))
    (let ([lib (directory-pair lib-root "lib")]
          [library (directory-pair library-root "library")]
          [roots '()]
          [root-parts '()]
          [search-own (library-search-handler)])
      (define (searched) (cons lib (append roots (list library))))
      ;; A name's first part may hold a dot, as (foo.bar) does, so only a
      ;; whole extension is cut from an entry.
      (define (entry-parts entry extensions)
        (let ([n (string-length entry)])
          (fold-left
            (lambda (parts extension)
              (let ([m (string-length extension)])
                (if (and (fx> n m) (string=? (substring entry (fx- n m) n) extension))
                    (cons (substring entry 0 (fx- n m)) parts)
                    parts)))
            (list entry)
            extensions)))
      (define (first-parts root)
        (let ([parts (make-hashtable string-hash string=?)]
              [extensions (map car (library-extensions))])
          (for-each (lambda (entry)
                      (for-each (lambda (part) (hashtable-set! parts part #t)) (entry-parts entry extensions)))
                    (guard (c [(i/o-error? c) '()]) (directory-list (car root))))
          parts))
      ;; With many roots, trying each for every lookup costs more than the
      ;; rest of start-up, so each root's top entries are listed when the
      ;; roots are set, and a lookup tries only the roots that hold the
      ;; name's first part. A name has one provider, so their order does not
      ;; matter. A name missed there, as one written into a root since, is
      ;; looked for in every root.
      (define (search who name extensions)
        (let* ([part (symbol->string (car name))]
               [likely (fold-right (lambda (entry kept)
                                     (if (hashtable-contains? (cdr entry) part) (cons (car entry) kept) kept))
                                   '() root-parts)])
          (let-values ([(source object found?)
                        (default-library-search-handler who name (cons lib (append likely (list library))) extensions)])
            (if (or source found?)
                (values source object found?)
                (default-library-search-handler who name (searched) extensions)))))
      ;; A lookup on another thread never loads, so it only picks the message.
      (define (refuse-lookup who name extensions)
        (let-values ([(source object found?) (default-library-search-handler who name (searched) extensions)])
          (if (and source (not (tuna-file? source)))
              (assertion-violation who "a library is first loaded on the main thread" name)
              (check-main-thread who))))
      (set! lib-prefix (string-append lib-root "/"))
      (set! source-roots (lambda () (map car (searched))))
      (set! set-roots!
        (lambda (new)
          (set! roots new)
          (set! root-parts (map (lambda (root) (cons root (first-parts root))) new))
          (library-directories (append own-directories (searched)))))
      ;; Chez's search handler reports any raise inside it, a quit included,
      ;; as an invalid library name.
      (set! find-module
        (lambda (who name extensions)
          (with-quits-allowed #f
            (cond
              [(memq (car name) '(tuna chez-lang))
               (search-own who name own-directories extensions)]
              [(refused-module-name? name)
               (errorf who "a module cannot be named ~s" name)]
              [(on-main-thread?)
               (let-values ([(source object found?) (search who name extensions)])
                 (when source
                   (hashtable-set! found-libraries name source))
                 (values source object found?))]
              [else (refuse-lookup who name extensions)]))))
      (set-roots! '())
      (library-search-handler
        (lambda (who name directories extensions)
          (find-module who name extensions)))))

  ;; chez-lang names a library from its path under library-directories, so
  ;; a root joins them before its modules compile.
  (define (set-library-roots! roots)
    (unless (and (list? roots)
                 (for-all (lambda (root) (and (pair? root) (string? (car root)) (string? (cdr root)))) roots))
      (assertion-violation 'set-library-roots! "not a list of library directory pairs" roots))
    (check-main-thread 'set-library-roots!)
    (set-roots! roots))

  (define (found-library-source name)
    (hashtable-ref found-libraries name #f))

  ;; library-list would build a list of every library; Chez's only other
  ;; test of a loaded library is this raise.
  (define (library-loaded? name)
    (guard (c [(assertion-violation? c) #f])
      (library-version name)
      #t))

  (define (found-libraries-under folder)
    (let ([prefix (string-append folder "/")])
      (filter (lambda (name) (string-prefix? prefix (hashtable-ref found-libraries name #f)))
              (vector->list (hashtable-keys found-libraries)))))

  (define (loaded-libraries-under folder)
    (filter library-loaded? (found-libraries-under folder)))

  (define (search-library who name)
    (find-module who name (library-extensions)))

  (define (module-exists? name)
    (let-values ([(source object found?) (search-library 'module-exists? name)])
      (and (or source found?) #t)))

  (define (split-path path)
    (let loop ([chars (string->list path)] [part '()] [parts '()])
      (cond
        [(null? chars) (reverse (cons (list->string (reverse part)) parts))]
        [(char=? (car chars) #\/) (loop (cdr chars) '() (cons (list->string (reverse part)) parts))]
        [else (loop (cdr chars) (cons (car chars) part) parts)])))

  ;; Paths are compared as strings with the paths the lookup found, which
  ;; are absolute and have no "." or ".." parts and no repeated "/".
  (define (normal-path path)
    (let loop ([parts (split-path (if (path-absolute? path)
                                      path
                                      (string-append (current-directory) "/" path)))]
               [kept '()])
      (cond
        [(null? parts)
         (if (null? kept)
             "/"
             (call-with-string-output-port
               (lambda (p) (for-each (lambda (part) (put-char p #\/) (put-string p part)) (reverse kept)))))]
        [(member (car parts) '("" ".")) (loop (cdr parts) kept)]
        [(string=? (car parts) "..") (loop (cdr parts) (if (null? kept) kept (cdr kept)))]
        [else (loop (cdr parts) (cons (car parts) kept))])))

  (define (tuna-file? path)
    (and (file-exists? path)
         (call-with-input-file path (lambda (p) (equal? (get-string-n p 6) "#!tuna")))))

  ;; A file under a library root is the module its path names only if the
  ;; lookup finds that file for the name; an earlier root may hold another,
  ;; and then evaluating a #!tuna file as plain forms would fail on its
  ;; first line.
  (define (path-module who path)
    (or (find (lambda (name) (string=? (hashtable-ref found-libraries name #f) path))
              (vector->list (hashtable-keys found-libraries)))
        (exists
          (lambda (root)
            (let ([prefix (string-append root "/")])
              (and (string-prefix? prefix path)
                   (let ([name (map string->symbol
                                    (split-path (path-root (substring path (string-length prefix)
                                                                      (string-length path)))))])
                     (and (not (refused-module-name? name))
                          (let-values ([(source object found?) (search-library who name)])
                            (cond
                              [(not source) #f]
                              [(string=? source path) name]
                              [(tuna-file? path)
                               (errorf who "~a is not a module: module ~s is ~a" path name source)]
                              [else #f])))))))
          (source-roots))))

  ;; Chez runs the bodies of the imports a module refers to before the
  ;; module's own; Tuna runs the others too, so every imported module has
  ;; run, on its own behalf, before the importer's body. A library's body
  ;; cannot be wrapped, so the owner and quits-allowed are set here for it,
  ;; and module-finished! puts back the invoking code's.
  (define (module-started! name specs)
    (check-main-thread 'import)
    (let ([previous (cons (current-owner-record) (quits-allowed))])
      (with-quits-allowed #f
        (let ([imported (filter (lambda (import) (and import (hashtable-contains? found-libraries import)))
                                (map import-spec-library specs))]
              [lib? (lib-library? name)])
          (let ([m (or (hashtable-ref modules name #f)
                       (let ([m (make-module-state '() #f 0)])
                         (hashtable-set! modules name m)
                         m))])
            (module-state-imports-set! m imported)
            (module-state-stale?-set! m #f)
            (module-state-generation-set! m (+ (module-state-generation m) 1))
            (module-state-environment-set! m #f))
          (set! running-bodies (cons name running-bodies))
          (module-definitions-started! name)
          (run-modules! imported)
          (unless lib?
            (for-each move-imported-lib-module! imported))
          (rank-module! name lib?)))
      (set-current-owner! (find-owner name))
      (set-quits-allowed! #t)
      previous))

  ;; A body that fails is marked as the stack unwinds, where quits wait: a
  ;; handler runs with the raising body's quits allowed, so a quit could
  ;; land before it marked anything.
  (define (run-module! name)
    (unless (module-loaded? name)
      (when (module-stale? name)
        (load-again! name))
      (let ([invoked? #f])
        (with-quits-allowed #f
          (dynamic-wind
            void
            (lambda () (invoke-module! name) (set! invoked? #t))
            (lambda () (unless invoked? (mark-failed! name))))))))

  ;; Quits wait outside the bodies, so none lands between a body's end and
  ;; Chez recording the library as invoked: Chez would run the body again.
  (define (invoke-module! name)
    (with-quits-allowed #f
      (call-with-library-lock (lambda () (invoke-library name)))))

  ;; The lock is taken and let go with quits deferred, as with
  ;; with-quit-safe-mutex, but the code holding it keeps the caller's
  ;; quits-allowed, so that a long load, a compile or a runaway macro can
  ;; be quit.
  (define (call-with-quit-safe-library-lock thunk)
    (let ([allowed (quits-allowed)])
      (with-quits-allowed #f
        (call-with-library-lock
          (lambda () (with-quits-allowed allowed (thunk)))))))

  ;; Chez's check of whether a library needs recompiling treats any raise
  ;; while it reads an object file as a reason to recompile, and so would
  ;; swallow a quit. reload-library runs that check on every library it
  ;; reaches, so quits wait through it. An import expanded at the top level
  ;; runs the check too, but deferring there would defer the whole
  ;; expansion; a quit lost there must be requested again. A stale module
  ;; is recompiled only when it is loaded again, so its source may have
  ;; gone or stopped compiling in the meantime.
  (define (reload-module-library name)
    (with-quits-allowed #f
      (reload-library name (lambda (importer) (not (module-stale? importer))))))

  ;; Chez's library manager is shared by every thread, so the main thread
  ;; expands, and so loads libraries, under the lock that other threads'
  ;; imports take.
  (define (call-with-locked-expansion thunk)
    (parameterize ([current-expand
                    (let ([expand (current-expand)])
                      (lambda arguments
                        (call-with-quit-safe-library-lock (lambda () (apply expand arguments)))))])
      (thunk)))

  (define (run-modules! names)
    (for-each run-module! (filter (lambda (name) (hashtable-contains? found-libraries name)) names)))

  ;; Chez runs the bodies of the imports a library refers to before the
  ;; library's own, so a raise there leaves a module whose body never
  ;; started; it is unloaded all the same, so its names are shadowed and the
  ;; next load starts from a new instance. library-requirements raises for
  ;; a library loaded only to be run.
  (define (mark-failed! name)
    (when (and (hashtable-contains? found-libraries name) (not (member name running-bodies)))
      (let ([m (hashtable-ref modules name #f)])
        (cond
          [m (module-state-stale?-set! m #t)
             (module-state-generation-set! m (+ (module-state-generation m) 1))]
          [else
           (hashtable-set! modules name
             (make-module-state
               (filter (lambda (import) (hashtable-contains? found-libraries import))
                       (guard (c [(violation? c) '()])
                         (library-requirements name (library-requirements-options import))))
               #t 1))])
        (set! failed-loads (cons name failed-loads)))))

  (define (move-imported-lib-module! name)
    (when (lib-library? name)
      (let ([m (hashtable-ref modules name #f)])
        (when m (for-each move-imported-lib-module! (module-state-imports m))))
      (move-before-importers! name)))

  ;; A raise from module-loaded's advice must not fail the body: Chez would
  ;; run the body of a library whose invocation failed again on its next
  ;; reference.
  (define (module-finished! name previous)
    (set-quits-allowed! #f)
    (set! running-bodies (remove name running-bodies))
    (unload-removed-definitions! name)
    (let ([m (hashtable-ref modules name #f)])
      (unless (module-state-loaded? m)
        (module-state-loaded?-set! m #t)
        (set! load-order (cons name load-order))))
    (for-each (lambda (handler) (handler name)) module-loaded-handlers)
    (call-module-code (lambda () (module-loaded name)))
    (set-current-owner! (car previous))
    (set-quits-allowed! (cdr previous)))

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

  (meta define (import-form? form)
    (syntax-case form ()
      [(i . specs) (and (identifier? #'i) (free-identifier=? #'i #'import))]
      [_ #f]))

  ;; (rnrs)'s exit and dynamic-wind are bindings distinct from Chez's, and
  ;; an import of (rnrs) gives them back too.
  (meta define replaced-chez-bindings
    (list (list 'exit #'chez:exit #'rnrs:exit)
          (list 'fork-thread #'chez:fork-thread)
          (list 'dynamic-wind #'chez:dynamic-wind #'rnrs:dynamic-wind)
          (list 'with-mutex #'chez:with-mutex)
          (list 'sleep #'chez:sleep)
          (list 'set-timer #'chez:set-timer)
          (list 'timer-interrupt-handler #'chez:timer-interrupt-handler)
          (list 'make-engine #'chez:make-engine)))

  ;; Follows an import, where the names it gave are bound in its context.
  ;; A habitual (import (chezscheme)) would otherwise silently undo what
  ;; Tuna replaces.
  (define-syntax check-import
    (lambda (x)
      (syntax-case x ()
        [(_ form)
         (let ([back (map car
                          (filter
                            (lambda (entry)
                              (let ([id (syntax-case #'form () [(i . specs) (datum->syntax #'i (car entry))])])
                                (exists (lambda (chez) (free-identifier=? id chez)) (cdr entry))))
                            replaced-chez-bindings))])
           (unless (null? back)
             (syntax-violation 'import
               (format "gives back Chez's ~{~a~^, ~}, which Tuna replaces or withholds; import ~a under another name"
                 back (if (null? (cdr back)) "it" "them"))
               #'form))
           #'(begin))])))

  (define-syntax module-forms
    (lambda (x)
      (lambda (lookup)
        (syntax-case x ()
          [(_ name previous) #'(module-finished! 'name previous)]
          [(k name previous (b form ...) rest ...)
           (and (identifier? #'b) (free-identifier=? #'b #'begin))
           #'(k name previous form ... rest ...)]
          [(k name previous form rest ...)
           (import-form? #'form)
           #'(begin form (check-import form) (k name previous rest ...))]
          [(k name previous (d . definition) rest ...)
           (and (identifier? #'d) (free-identifier=? #'d #'define))
           #'(begin (define-public . definition) (k name previous rest ...))]
          [(k name previous form rest ...)
           (chez-definition? #'form)
           (let ([module (syntax->datum #'name)])
             (with-syntax ([(defined ...) (form-defined-names #'form lookup)])
               (with-syntax ([(symbol ...)
                              (map (lambda (id) (datum->syntax id (prefixed-symbol module (syntax->datum id))))
                                   #'(defined ...))])
                 #'(begin form (export (rename (defined symbol) ...)) (k name previous rest ...)))))]
          [(k name previous form rest ...)
           #'(begin form (k name previous rest ...))]))))

  (define (module-name-transformer x)
    (lambda (lookup)
      (syntax-case x ()
        [(k) #`'#,(datum->syntax #'k (lookup #'k #'module-property))])))

  ;; this-module and %scope are captured on purpose, from the keyword the
  ;; loader writes in the module's own context. A form given to %scope takes
  ;; that context, so it sees what the module's top-level code sees; that is
  ;; how eval-in-module works. The author's forms go in a module nested
  ;; inside the import of the names Tuna replaces, so that they may define
  ;; those names too. Each module's this-module is the one shared
  ;; transformer: a transformer written here would carry this library's
  ;; context into every module's object file.
  (define-syntax tuna-module-body
    (lambda (x)
      (syntax-case x ()
        [(k name form ...)
         (with-syntax ([this-module (datum->syntax #'k 'this-module)]
                       [%scope (datum->syntax #'k '%scope)]
                       [scope-symbol (datum->syntax #'k (prefixed-symbol (syntax->datum #'name) '%scope))]
                       [replaced (datum->syntax #'k '(tuna core replaced))]
                       [specs (datum->syntax #'k (import-specs #'(form ...)))])
           #'(begin
               (implicit-exports #t)
               (import replaced)
               (module body ()
                 (implicit-exports #t)
                 (define-syntax this-module module-name-transformer)
                 (define-property this-module module-property 'name)
                 (define-syntax %scope
                   (lambda (y)
                     (syntax-case y ()
                       [(_ e) (datum->syntax #'%scope (syntax->datum #'e))])))
                 (export (rename (%scope scope-symbol)))
                 (define previous (module-started! 'name 'specs))
                 (module-forms name previous form ...))
               (export (import body))))])))

  (define (scope-environment name scope)
    (let ([m (hashtable-ref modules name #f)])
      (or (module-state-environment m)
          (let ([env (call-with-quit-safe-library-lock (lambda () (environment `(only ,name ,scope))))])
            (module-state-environment-set! m env)
            env))))

  (define (own-changeable? module name)
    (and (symbol? name)
         (equal? (changeable-symbol-module (prefixed-symbol module name)) module)))

  (define (documentation-string body)
    (and (pair? body) (string? (car body)) (pair? (cdr body)) (car body)))

  ;; Chez names a procedure after the variable it is first bound to, so a
  ;; redefinition keeps its exported name only through this let.
  (define (definition->assignment module form)
    (define (named name expr)
      (let ([symbol (prefixed-symbol module name)])
        `(let ([,symbol ,expr]) ,symbol)))
    (if (and (pair? form) (eq? (car form) 'define) (pair? (cdr form)))
        (let ([head (cadr form)])
          (cond
            [(and (pair? head) (own-changeable? module (car head)))
             (values `(set! ,(car head) ,(named (car head) `(lambda ,(cdr head) ,@(cddr form))))
                     (car head) (documentation-string (cddr form)))]
            [(and (own-changeable? module head) (pair? (cddr form)) (null? (cdddr form)))
             (values `(set! ,head ,(named head (caddr form))) head #f)]
            [else (values form #f #f)]))
        (values form #f #f)))

  (define (eval-in-module form name)
    (unless (module-name? name)
      (assertion-violation 'eval-in-module "not a module name" name))
    (check-main-thread 'eval-in-module)
    (unless (module-loaded? name)
      (assertion-violation 'eval-in-module "not a loaded module" name))
    (let ([scope (prefixed-symbol name '%scope)])
      (let-values ([(form defined doc) (definition->assignment name form)])
        (as-module name
          (call-with-locked-expansion
            (lambda ()
              (call-with-values
                (lambda () (eval (list scope form) (scope-environment name scope)))
                (lambda results
                  (when defined
                    (set-changeable-documentation! (prefixed-symbol name defined) doc))
                  (apply values results)))))))))

  ;; Loading a library's object file again installs a new instance of the
  ;; same compiled code, whose body runs at the next invocation; code
  ;; compiled against the library keeps working, since the instance's
  ;; locations are the object's own.
  (define (load-object! bytes)
    (call-with-quit-safe-library-lock
      (lambda () (load-compiled-from-port (open-bytevector-input-port bytes)))))

  (define (object-bytes name)
    (let-values ([(source object found?) (search-library 'load-module! name)])
      (and object (file-exists? object)
           (call-with-port (open-file-input-port object) get-bytevector-all))))

  (define (load-again! name)
    (let ([bytes (object-bytes name)])
      (unless bytes
        (errorf 'load-module! "~s cannot load again: it has no object file" name))
      (load-object! bytes)
      (module-state-stale?-set! (hashtable-ref modules name #f) #f)))

  ;; Recompiling an import puts its importers out of date, so every module
  ;; is recompiled before any body runs.
  (define (install-again! names)
    (let ([recompiled (fold-left (lambda (recompiled name)
                                   (append (reload-module-library name) recompiled))
                                 '() names)])
      (for-each
        (lambda (name)
          (if (member name recompiled)
              (module-state-stale?-set! (hashtable-ref modules name #f) #f)
              (load-again! name)))
        names)))

  ;; Imports come first, so that each importer is recompiled against its
  ;; imports' new versions.
  (define (with-stale-imports name)
    (let ([seen (make-hashtable equal-hash equal?)])
      (reverse
        (let visit ([name name] [ordered '()])
          (cond
            [(or (hashtable-contains? seen name) (not (module-stale? name))) ordered]
            [else
             (hashtable-set! seen name #t)
             (cons name
                   (fold-left (lambda (ordered import) (visit import ordered))
                              ordered
                              (module-state-imports (hashtable-ref modules name #f))))])))))

  ;; Each comes before its importers, the order their bodies must run in.
  (define (with-loaded-importers name)
    (let ([seen (make-hashtable equal-hash equal?)])
      (let visit ([name name] [ordered '()])
        (cond
          [(hashtable-contains? seen name) ordered]
          [else
           (hashtable-set! seen name #t)
           (cons name
                 (fold-left (lambda (ordered importer) (visit importer ordered))
                            ordered
                            (loaded-importers name)))]))))

  (define module-loaded-handlers '())
  (define module-unloaded-handlers '())

  ;; Defining an option, hook or table is not a change, so module-changes
  ;; does not list it; what such a definition needs when its module
  ;; unloads, and not when it reloads, is done by a handler.
  (define (add-module-loaded-handler! handler)
    (set! module-loaded-handlers (append module-loaded-handlers (list handler))))

  (define (add-module-unloaded-handler! handler)
    (set! module-unloaded-handlers (append module-unloaded-handlers (list handler))))

  (define (on-unload thunk)
    (unless (procedure? thunk)
      (assertion-violation 'on-unload "not a procedure" thunk))
    (record-change! 'on-unload 'unload-action thunk #f void void)
    (void))

  (define (take-back-changes! owner kept-kinds)
    (with-quits-allowed #f
      (for-each
        (lambda (c)
          (when (eq? (change-kind c) 'unload-action)
            (take-back! c)
            (call-as-owner (find-owner owner) (lambda () (call-module-code (change-thing c))))))
        (owner-changes owner))
      (for-each take-back! (remp (lambda (c) (memq (change-kind c) kept-kinds)) (owner-changes owner)))))

  ;; In a diamond an importer is unloaded through another importer first.
  (define (unload-instance! name)
    (with-quits-allowed #f
      (for-each (lambda (importer) (when (module-loaded? importer) (unload-instance! importer)))
                (loaded-importers name))
      (take-back-changes! name '())
      (unload-definitions! name)
      (for-each (lambda (handler) (handler name)) module-unloaded-handlers)
      (let ([m (hashtable-ref modules name #f)])
        (module-state-loaded?-set! m #f)
        (module-state-stale?-set! m #t)
        (module-state-generation-set! m (+ (module-state-generation m) 1))
        (module-state-environment-set! m #f))
      (set! load-order (remove name load-order))
      (unrank-module! name)))

  ;; A module in kept is being reloaded and gets its previous version back;
  ;; any other body a raise left unfinished was a first load.
  (define (drop-failed-bodies! depth kept)
    (with-quits-allowed #f
      (let loop ()
        (when (fx> (length running-bodies) depth)
          (let ([name (car running-bodies)])
            (set! running-bodies (cdr running-bodies))
            (set! failed-loads (cons name failed-loads))
            (unless (member name kept)
              (unload-instance! name))
            (loop))))))

  (define failed-loads '())

  ;; The modules are unloaded or restored, so module-failed runs on behalf
  ;; of the code that loaded them.
  (define (call-module-failed owner)
    (unless (null? failed-loads)
      (let ([names (reverse failed-loads)])
        (set! failed-loads '())
        (call-as-owner owner
          (lambda ()
            (for-each (lambda (name) (call-module-code (lambda () (module-failed name)))) names))))))

  ;; Every entry that can run module bodies goes through here, so a body
  ;; that raises leaves neither its owner nor a half-loaded module behind.
  ;; Failed bodies are dropped as the stack unwinds, not in a handler, so
  ;; a raise reaches report with its stack intact; quits wait from the end
  ;; of thunk, since one landing before the drop would skip it. No body is
  ;; running when a task pauses, so a pause drops nothing.
  (define (call-loading-modules thunk)
    (let ([depth (length running-bodies)] [allowed (quits-allowed)] [owner (current-owner-record)])
      (call-as-owner owner
        (lambda ()
          (with-quits-allowed #f
            (dynamic-wind
              void
              (lambda () (with-quits-allowed allowed (thunk)))
              (lambda ()
                (drop-failed-bodies! depth '())
                (call-module-failed owner))))))))

  (define (load-unloaded-modules! names)
    (for-each (lambda (name) (when (module-stale? name) (load-module! name))) names))

  (define (load-module! name)
    (unless (module-name? name)
      (assertion-violation 'load-module! "not a module name" name))
    (check-main-thread 'load-module!)
    (unless (module-loaded? name)
      (let ([stale (with-stale-imports name)])
        (let-values ([(source object found?) (search-library 'load-module! name)])
          (unless (and source (hashtable-contains? found-libraries name))
            (assertion-violation 'load-module! "not a module" name)))
        (call-loading-modules
          (lambda ()
            (install-again! stale)
            (run-module! name))))
      (unless (module-loaded? name)
        (assertion-violation 'load-module! "not a module" name))))

  (define (unload-module! name)
    (unless (module-name? name)
      (assertion-violation 'unload-module! "not a module name" name))
    (check-main-thread 'unload-module!)
    (unless (module-loaded? name)
      (assertion-violation 'unload-module! "not a loaded module" name))
    (unload-instance! name))

  ;; Newest first, so each module goes before what it imports.
  (define (unload-all-modules!)
    (for-each (lambda (name) (when (module-loaded? name) (call-reporting (lambda () (unload-instance! name)))))
              load-order))

  (define (running-object name)
    (or (module-state-running-object (hashtable-ref modules name #f)) (object-bytes name)))

  (define (take-back-for-reload! order)
    (for-each (lambda (name) (take-back-changes! name '(define))) (reverse order)))

  (define (restore! order previous depth)
    (with-quits-allowed #f
      (drop-failed-bodies! depth order)
      (take-back-for-reload! order)
      (for-each
        (lambda (name bytes)
          (when bytes
            (load-object! bytes)
            (module-state-running-object-set! (hashtable-ref modules name #f) bytes)))
        order previous)
      (call-reporting
        (lambda () (call-loading-modules (lambda () (for-each invoke-module! order)))))))

  ;; reload-library puts the previous versions back after a compile error,
  ;; but not after a body raises, and not the version running after an
  ;; earlier failed reload, which differs from the object on disk; so the
  ;; objects running now are kept. The failure is reported by the only
  ;; handler, so a quit landing in the report ends the report alone, and
  ;; quits wait from the escape until the previous versions are back.
  (define (reload-module! name)
    (check-main-thread 'eval-file)
    (unless (module-loaded? name)
      (assertion-violation 'eval-file "not a loaded module" name))
    (let* ([order (with-loaded-importers name)]
           [previous (map running-object order)]
           [depth (length running-bodies)]
           [allowed (quits-allowed)]
           [owner (current-owner-record)])
      (call-as-owner owner
        (lambda ()
          (with-quits-allowed #f
            (or (call/1cc
                  (lambda (k)
                    (call-with-only-handler
                      (lambda (c) (report-safely c) (k #f))
                      (lambda ()
                        (with-quits-allowed allowed
                          (call-with-warnings-reported
                            (lambda ()
                              (take-back-for-reload! order)
                              (let ([recompiled (reload-module-library name)])
                                (for-each (lambda (module) (unless (member module recompiled) (load-again! module)))
                                          order))
                              (for-each invoke-module! order))))
                        (for-each (lambda (module) (module-state-running-object-set! (hashtable-ref modules module #f) #f))
                                  order)
                        ;; A body may have caught the raise of an import's
                        ;; body, which then never finished.
                        (drop-failed-bodies! depth '())
                        (call-module-failed owner)
                        #t))))
                ;; The raising body left its own module as the owner.
                (begin (call-as-owner owner (lambda () (restore! order previous depth))) #f))))))))
