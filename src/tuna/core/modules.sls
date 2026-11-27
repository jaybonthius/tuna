(library (tuna core modules)
  (export
    tuna-module-body
    define-public
    this-module-name
    check-import
    install-module-lookup!
    module-name?
    prefixed-symbol
    loaded-modules
    module-owner
    load-module!
    reload-modules!
    unload-owner!
    eval-in-module
    start-top-level!
    install-exit-runner!)
  (import (except (chezscheme) exit) (tuna core kernel) (tuna core conditions) (tuna core names)
          (prefix (only (chezscheme) exit fork-thread dynamic-wind with-mutex sleep set-timer
                        timer-interrupt-handler make-engine collect-request-handler
                        keyboard-interrupt-handler condition-wait register-signal-handler
                        with-interrupts-disabled critical-section disable-interrupts enable-interrupts
                        $primitive generate-interrupt-trap library-search-handler)
                  chez:)
          (prefix (only (rnrs) exit dynamic-wind) rnrs:)
          (only (lang body) form-defined-names unbound-identifier?)
          (only (lang language) call-with-library-lock)
          (only (lang reload) reload-library))

  ;;; Modules

  ;; A module is stale once its library instance has run and been unloaded:
  ;; Chez runs a library's body once per instance, so running it again needs
  ;; a new instance. Chez never frees an environment, so each instance makes
  ;; one, for eval-in-module, when first needed.
  (define-record-type module-state
    (nongenerative)
    (sealed #t)
    (fields name (mutable instance) (mutable imports) (mutable loaded?) (mutable stale?)
            (mutable environment) (mutable running-object) (mutable rank))
    (protocol
      (lambda (new)
        (lambda (name) (new name #f '() #f #f #f #f #f)))))

  (define found-libraries (make-hashtable equal-hash equal?))
  (define modules (make-hashtable equal-hash equal?))
  (define load-order '())

  (define (module-of name)
    (or (hashtable-ref modules name #f)
        (let ([m (make-module-state name)])
          (hashtable-set! modules name m)
          m)))

  (define (module-loaded? name)
    (let ([m (hashtable-ref modules name #f)])
      (and m (module-state-loaded? m))))

  (define (module-stale? name)
    (let ([m (hashtable-ref modules name #f)])
      (and m (module-state-stale? m))))

  (define (loaded-modules) (reverse load-order))

  ;; Any thread looks owners up, so the main thread replaces this table
  ;; whole and never changes it in place.
  (define loaded-instances (hashtable-copy (make-hashtable equal-hash equal?) #f))

  (define (set-module-loaded! m loaded?)
    (module-state-loaded?-set! m loaded?)
    (let ([table (hashtable-copy loaded-instances #t)])
      (if loaded?
          (hashtable-set! table (module-state-name m) (module-state-instance m))
          (hashtable-delete! table (module-state-name m)))
      (set! loaded-instances (hashtable-copy table #f))))

  (define (module-owner name)
    (unless (module-name? name) (assertion-violation 'module-owner "not a module name" name))
    (hashtable-ref loaded-instances name #f))

  (define (owner-module o)
    (and (eq? (owner-kind o) 'module)
         (let ([m (hashtable-ref modules (owner-name o) #f)])
           (and m (eq? (module-state-instance m) o) m))))

  (define (loaded-importers name)
    (filter (lambda (importer) (member name (module-state-imports (hashtable-ref modules importer #f))))
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

  ;;; Lookup

  (define (refused-module-name? name)
    (memq (car name) '(csv7 r6rs)))

  (define (tuna-file? path)
    (and (file-exists? path)
         (call-with-input-file path (lambda (p) (equal? (get-string-n p 6) "#!tuna")))))

  ;; The start roots come first, then library-directories as the plugin
  ;; manager sets them. Tuna's own names resolve only to Tuna's libraries, so
  ;; no file in a root or the working folder replaces the kernel. With many
  ;; roots, trying each for every lookup costs more than the rest of
  ;; start-up, so each root's top entries are listed once per list of roots
  ;; and a lookup tries first the roots that hold the name's first part.
  (define (install-module-lookup! own-directories start-roots)
    (let ([search-own (library-search-handler)] [index (cons #f #f)])
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
      (define (first-parts root extensions)
        (let ([parts (make-hashtable string-hash string=?)])
          (for-each (lambda (entry)
                      (for-each (lambda (part) (hashtable-set! parts part #t)) (entry-parts entry extensions)))
                    (guard (c [(i/o-error? c) '()]) (directory-list (car root))))
          (hashtable-keys parts)))
      (define (part-roots roots)
        (let ([table (make-hashtable string-hash string=?)] [extensions (map car (library-extensions))])
          (for-each
            (lambda (root)
              (vector-for-each
                (lambda (part) (hashtable-update! table part (lambda (holders) (cons root holders)) '()))
                (first-parts root extensions)))
            (reverse roots))
          table))
      ;; Any thread may search, so a new index replaces the old whole, in
      ;; one assignment, and is never changed after.
      (define (roots)
        (let ([directories (library-directories)] [current index])
          (if (eq? (car current) directories)
              (cdr current)
              (let* ([all (remp (lambda (root) (member root own-directories)) directories)]
                     [indexed (cons all (part-roots all))])
                (set! index (cons directories indexed))
                indexed))))
      (define (search who name extensions)
        (let ([indexed (roots)])
          (let-values ([(source object found?)
                        (default-library-search-handler who name
                          (hashtable-ref (cdr indexed) (symbol->string (car name)) '()) extensions)])
            (if (or source found?)
                (values source object found?)
                (default-library-search-handler who name (car indexed) extensions)))))
      (define (refuse-lookup who name extensions)
        (let-values ([(source object found?) (search who name extensions)])
          (if (and source (not (tuna-file? source)))
              (assertion-violation who "a library is first loaded on the main thread" name)
              (values source object found?))))
      (library-directories (append own-directories start-roots))
      (library-search-handler
        (lambda (who name directories extensions)
          (cond
            [(memq (car name) '(tuna lang)) (search-own who name own-directories extensions)]
            [(refused-module-name? name) (errorf who "a module cannot be named ~s" name)]
            [(on-main-thread?)
             (let-values ([(source object found?) (search who name extensions)])
               (when source (hashtable-set! found-libraries name source))
               (values source object found?))]
            [(hashtable-ref found-libraries name #f) (search who name extensions)]
            [else (refuse-lookup who name extensions)])))))

  (define (search-library who name)
    ((library-search-handler) who name (library-directories) (library-extensions)))

  ;;; Module bodies

  (define module-property)
  (define assigned-property)

  (meta define (site-module id lookup)
    (let ([probe (datum->syntax id 'this-module)])
      (and (not (unbound-identifier? probe))
           (lookup probe #'module-property))))

  ;; A rank above every import keeps the rank it had, so a reload with
  ;; unchanged imports gives the value before; otherwise the next rank,
  ;; above every module so far.
  (define next-rank 1)
  (define forced-ranks (make-hashtable equal-hash equal?))

  (define (module-rank name imported)
    (cond
      [(hashtable-ref forced-ranks name #f)]
      [else
       (let ([previous (module-state-rank (module-of name))]
             [highest (fold-left (lambda (h import)
                                   (let ([i (module-owner import)]) (if i (max h (owner-rank i)) h)))
                                 0 imported)])
         (if (and previous (> previous highest))
             previous
             (let ([r next-rank]) (set! next-rank (+ next-rank 1)) r)))]))

  ;; A load reached through Chez's import is an operation of its own: it may
  ;; not run while another operation is under way, since that operation may
  ;; be unloading what it imports.
  (define (module-started! name specs)
    (check-main-thread 'import)
    (when (and doing (not (eq? (current-task) doing-task)))
      (errorf 'import "cannot load ~s while an operation on modules is under way" name))
    (let ([imported (filter (lambda (import) (and import (hashtable-contains? found-libraries import)))
                            (map import-spec-library specs))])
      (run-modules! imported)
      (let* ([m (module-of name)]
             [rank (module-rank name imported)]
             [instance (new-module-owner name rank)])
        (module-state-imports-set! m imported)
        (module-state-instance-set! m instance)
        (set-module-loaded! m #t)
        (module-state-stale?-set! m #f)
        (module-state-environment-set! m #f)
        (module-state-rank-set! m rank)
        (when doing (set! loaded-by-op (cons name loaded-by-op)))
        (begin-body! instance name failed-body!))))

  ;; A raise from module-loaded's advice must not fail the body: Chez would
  ;; run the body of a library whose invocation failed again on its next
  ;; reference.
  (define (module-finished! running)
    (let* ([instance (running-body-instance running)] [name (owner-name instance)])
      (set! load-order (cons name (remove name load-order)))
      (set! top-level-behind (cons name top-level-behind))
      (call-reporting (lambda () (module-loaded instance)))
      (finish-body! running)))

  ;; A body that raises unloads its instance: the first step at once, the
  ;; rest between tasks.
  (define (failed-body! instance)
    (begin-unload! instance)
    (ask-op! (make-op 'finish-unload instance)))

  (define (run-module! name)
    (unless (module-loaded? name)
      (when (module-stale? name) (install-again! (list name)))
      (let ([invoked? #f] [outer (running-body-records)])
        (dynamic-wind
          void
          (lambda () (invoke-module! name) (set! invoked? #t))
          (lambda () (unless invoked? (drop-failed-bodies! outer name))))
        (when (null? outer) (sync-top-level!)))))

  ;; Visited as well as invoked: a library invoked from its object file
  ;; without its compile-time information cannot be imported at the top
  ;; level after.
  (define (invoke-module! name)
    (call-with-library-lock
      (lambda ()
        (eval `(let () (import (only ,name)) #f) (scheme-environment))
        (invoke-library name))))

  (define (run-modules! names)
    (for-each run-module! (filter (lambda (name) (hashtable-contains? found-libraries name)) names)))

  ;; Chez runs the bodies of the imports a library refers to before its
  ;; own, so a raise there leaves the modules on the way to it with bodies
  ;; that never started. Each is marked stale all the same, with the
  ;; imports Chez records for it, so the next load starts from new
  ;; instances and reaches the stale import that raised. A library that
  ;; failed to compile is gone from Chez, so the next load compiles it
  ;; anew; a plain library is left to Chez, which runs its body again.
  (define (drop-failed-bodies! outer name)
    (for-each (lambda (b) (unless (memq b outer) (drop-body! b))) (running-body-records))
    (forget-raised-in-body!)
    (let mark ([name name])
      (let ([source (hashtable-ref found-libraries name #f)])
        (when (and source (not (module-loaded? name)) (not (module-stale? name)) (tuna-file? source)
                   (call-with-library-lock (lambda () (member name (library-list)))))
          (let ([m (module-of name)]
                [imports (filter (lambda (import) (hashtable-contains? found-libraries import))
                                 (call-with-library-lock
                                   (lambda () (library-requirements name (library-requirements-options import)))))])
            (module-state-imports-set! m imports)
            (module-state-stale?-set! m #t)
            (for-each mark imports))))))

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
  ;; exported here; define-public exports its own names, so a macro built on
  ;; it needs nothing, and a name a macro defines with Chez's forms stays
  ;; private, as in a Chez module.
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

  ;; R6RS forbids exporting an assigned variable, so a % name the module's
  ;; own code sets is module state, kept unexported; any other assigned name
  ;; is the error Chez reports.
  (meta define (assigned-private-names forms)
    (let walk ([x forms] [found '()])
      (cond
        [(and (pair? x) (eq? (car x) 'set!) (pair? (cdr x)) (symbol? (cadr x))
              (let ([s (symbol->string (cadr x))]) (and (fx> (string-length s) 0) (char=? (string-ref s 0) #\%)))
              (not (memq (cadr x) found)))
         (walk (cddr x) (cons (cadr x) found))]
        [(pair? x) (walk (cdr x) (walk (car x) found))]
        [(vector? x) (walk (vector->list x) found)]
        [else found])))

  (meta define (private-name? id)
    (let ([s (symbol->string (syntax->datum id))])
      (and (fx> (string-length s) 0) (char=? (string-ref s 0) #\%))))

  (meta define (assigned-state? id lookup)
    (let ([probe (datum->syntax id 'this-module)])
      (and (not (unbound-identifier? probe))
           (let ([assigned (lookup probe #'assigned-property)])
             (and assigned (memq (syntax->datum id) assigned) #t)))))

  ;; (rnrs)'s exit and dynamic-wind are bindings distinct from Chez's, and
  ;; an import of (rnrs) gives them back too.
  (meta define replaced-chez-bindings
    (list (list 'exit #'chez:exit #'rnrs:exit)
          (list 'fork-thread #'chez:fork-thread)
          (list 'dynamic-wind #'chez:dynamic-wind #'rnrs:dynamic-wind)
          (list 'with-mutex #'chez:with-mutex)
          (list 'sleep #'chez:sleep)
          (list 'condition-wait #'chez:condition-wait)
          (list 'register-signal-handler #'chez:register-signal-handler)
          (list 'set-timer #'chez:set-timer)
          (list 'timer-interrupt-handler #'chez:timer-interrupt-handler)
          (list 'make-engine #'chez:make-engine)
          (list 'collect-request-handler #'chez:collect-request-handler)
          (list 'keyboard-interrupt-handler #'chez:keyboard-interrupt-handler)
          (list 'with-interrupts-disabled #'chez:with-interrupts-disabled)
          (list 'critical-section #'chez:critical-section)
          (list 'disable-interrupts #'chez:disable-interrupts)
          (list 'enable-interrupts #'chez:enable-interrupts)
          (list '$primitive #'chez:$primitive)
          (list 'generate-interrupt-trap #'chez:generate-interrupt-trap)
          (list 'library-search-handler #'chez:library-search-handler)))

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

  (define (define-value module symbol value doc)
    (if (procedure? value)
        (define-changeable! (module-state-instance (module-of module)) symbol value doc)
        value))

  ;; Chez names a procedure after the variable it is first bound to, so the
  ;; value is bound first to a variable named with the exported name: an
  ;; error or a stack sample then says which module's definition it is.
  (define-syntax define-public
    (lambda (x)
      (lambda (lookup)
        (define (parts form)
          (syntax-case form ()
            [(_ (name . formals) doc body1 body2 ...)
             (and (identifier? #'name) (string? (syntax->datum #'doc)))
             (values #'name #'(lambda formals body1 body2 ...) #'doc)]
            [(_ (name . formals) body1 body2 ...)
             (identifier? #'name)
             (values #'name #'(lambda formals body1 body2 ...) #f)]
            [(_ name expr) (identifier? #'name) (values #'name #'expr #f)]
            [(_ name) (identifier? #'name) (values #'name #'(void) #f)]
            [_ (syntax-violation 'define-public "invalid syntax" form)]))
        (syntax-case x ()
          [(_ head body ...)
           (let-values ([(name expr doc) (parts x)])
             (let ([module (site-module name lookup)])
               (if module
                   (with-syntax ([name name] [expr expr] [doc doc] [module (datum->syntax name module)]
                                 [symbol (datum->syntax name (prefixed-symbol module (syntax->datum name)))])
                     (if (or (private-name? #'name) (assigned-state? #'name lookup))
                         #'(define name (define-value 'module 'symbol (let ([symbol expr]) symbol) doc))
                         #'(begin
                             (define name (define-value 'module 'symbol (let ([symbol expr]) symbol) doc))
                             (export (rename (name symbol))))))
                   #'(define head body ...))))]))))

  (define-syntax module-forms
    (lambda (x)
      (lambda (lookup)
        (syntax-case x ()
          [(_ name running) #'(module-finished! running)]
          [(k name running (b form ...) rest ...)
           (and (identifier? #'b) (free-identifier=? #'b #'begin))
           #'(k name running form ... rest ...)]
          [(k name running form rest ...)
           (import-form? #'form)
           #'(begin form (check-import form) (k name running rest ...))]
          [(k name running (d . definition) rest ...)
           (and (identifier? #'d) (free-identifier=? #'d #'define))
           #'(begin (define-public . definition) (k name running rest ...))]
          [(k name running form rest ...)
           (chez-definition? #'form)
           (let ([module (syntax->datum #'name)])
             (with-syntax ([(defined ...) (remp (lambda (id) (or (private-name? id) (assigned-state? id lookup)))
                                                (form-defined-names #'form lookup))])
               (with-syntax ([(symbol ...)
                              (map (lambda (id) (datum->syntax id (prefixed-symbol module (syntax->datum id))))
                                   #'(defined ...))])
                 #'(begin form (export (rename (defined symbol) ...)) (k name running rest ...)))))]
          [(k name running form rest ...)
           #'(begin form (k name running rest ...))]))))

  (define (module-name-transformer x)
    (lambda (lookup)
      (syntax-case x ()
        [(k) #`'#,(datum->syntax #'k (lookup #'k #'module-property))])))

  (define-syntax this-module-name
    (lambda (x) (syntax-violation 'this-module "only in a module's code" x)))

  ;; this-module and %scope are captured on purpose, from the keyword the
  ;; loader writes in the module's own context. A form given to %scope takes
  ;; that context, so it sees what the module's top-level code sees; that is
  ;; how eval-in-module works. The author's forms go in a module nested
  ;; inside the import of the names Tuna replaces, so that they may define
  ;; those names too.
  (define-syntax tuna-module-body
    (lambda (x)
      (syntax-case x ()
        [(k name form ...)
         (with-syntax ([this-module (datum->syntax #'k 'this-module)]
                       [%scope (datum->syntax #'k '%scope)]
                       [scope-symbol (datum->syntax #'k (prefixed-symbol (syntax->datum #'name) '%scope))]
                       [replaced (datum->syntax #'k '(tuna core replaced))]
                       [specs (datum->syntax #'k (import-specs #'(form ...)))]
                       [assigned (datum->syntax #'k (assigned-private-names (syntax->datum #'(form ...))))])
           #'(begin
               (implicit-exports #t)
               (import replaced)
               (module body ()
                 (implicit-exports #t)
                 (define-syntax this-module module-name-transformer)
                 (define-property this-module module-property 'name)
                 (define-property this-module assigned-property 'assigned)
                 (define-syntax %scope
                   (lambda (y)
                     (syntax-case y ()
                       [(_ e) (datum->syntax #'%scope (syntax->datum #'e))])))
                 (export (rename (%scope scope-symbol)))
                 (define running (module-started! 'name 'specs))
                 (module-forms name running form ...))
               (export (import body))))])))

  ;;; Loading again and reloading

  ;; Loading a library's object file again installs a new instance of the
  ;; same compiled code, whose body runs at the next invocation; code
  ;; compiled against the library keeps working, since the instance's
  ;; locations are the object's own.
  (define (load-object! bytes)
    (call-with-library-lock
      (lambda () (load-compiled-from-port (open-bytevector-input-port bytes)))))

  (define (object-bytes name)
    (let-values ([(source object found?) (search-library 'load-module! name)])
      (and object (file-exists? object)
           (call-with-port (open-file-input-port object) get-bytevector-all))))

  ;; Visited as well as invoked, so the top level can import it again.
  (define (load-again! name bytes)
    (unless bytes
      (errorf 'load-module! "~s cannot load again: it has no object file" name))
    (load-object! bytes)
    (module-state-stale?-set! (module-of name) #f))

  (define (running-object name)
    (or (module-state-running-object (module-of name)) (object-bytes name)))

  ;; Chez's check of whether a library needs recompiling runs on every
  ;; library reload-library reaches. A stale module is recompiled only when
  ;; it is loaded again, so its source may have gone meanwhile; the
  ;; importers a reload unloaded are stale by now and load again at once.
  ;; Only a library the lookup found can import a module, so Chez's own
  ;; and the kernel's are not read for their imports at every reload.
  (define (reload-module-library name reloading)
    (reload-library name
      (lambda (importer)
        (and (hashtable-contains? found-libraries importer)
             (or (member importer reloading) (not (module-stale? importer)))))))

  ;; An import recompiled since a stale module last loaded puts that
  ;; module's object out of date, so every stale module a load reaches is
  ;; recompiled where it needs to be before any body runs.
  (define (stale-modules-reached name)
    (let loop ([todo (list name)] [found '()])
      (cond
        [(null? todo) (imports-first found)]
        [(or (member (car todo) found) (not (module-stale? (car todo)))) (loop (cdr todo) found)]
        [else (loop (append (module-state-imports (module-of (car todo))) (cdr todo)) (cons (car todo) found))])))

  (define (install-again! names)
    (let ([recompiled (fold-left (lambda (recompiled name) (append (reload-module-library name names) recompiled))
                                 '() names)])
      (for-each (lambda (name)
                  (if (member name recompiled)
                      (module-state-stale?-set! (module-of name) #f)
                      (load-again! name (running-object name))))
                names)))

  ;; Modules that import none of each other load in the order they first
  ;; loaded, as at start, since a body may rely on what one loaded before
  ;; it did to a module both import.
  (define (with-loaded-importers names)
    (let loop ([todo names] [found '()])
      (cond
        [(null? todo)
         (let ([loaded (loaded-modules)] [found (reverse found)])
           (imports-first (append (filter (lambda (name) (member name found)) loaded)
                                  (remp (lambda (name) (member name loaded)) found))))]
        [(member (car todo) found) (loop (cdr todo) found)]
        [else (loop (append (cdr todo) (loaded-importers (car todo))) (cons (car todo) found))])))

  (define (imports-first names)
    (let ([seen (make-hashtable equal-hash equal?)] [ordered '()])
      (for-each
        (rec visit
          (lambda (name)
            (unless (hashtable-contains? seen name)
              (hashtable-set! seen name #t)
              (for-each (lambda (import) (when (member import names) (visit import)))
                        (module-state-imports (module-of name)))
              (set! ordered (cons name ordered)))))
        names)
      (reverse ordered)))

  ;;; Operations

  (define-record-type op
    (nongenerative)
    (sealed #t)
    (fields kind target (mutable how) (mutable detail) (mutable waiters) (mutable done?))
    (protocol
      (lambda (new) (lambda (kind target) (new kind target #f #f '() #f)))))

  (define asked '())
  (define doing #f)
  (define doing-task #f)
  (define runner-task #f)
  (define gate-waiters '())
  (define loaded-by-op '())

  (define (ask-op! op)
    (set! asked (append asked (list op)))
    (unless runner-task
      (set! runner-task (spawn-kernel-task (lambda (restore) (run-ops!))))))

  (define (wait-op op)
    (unless (op-done? op)
      (suspend (lambda (resume) (op-waiters-set! op (cons resume (op-waiters op))))))
    (if (eq? (op-how op) 'raised)
        (raise (op-detail op))
        (op-detail op)))

  (define (run-ops!)
    (let loop ()
      (cond
        [(null? asked)
         (set! runner-task #f)
         (let ([ws gate-waiters])
           (set! gate-waiters '())
           (for-each (lambda (resume) (resume void)) ws))]
        [else
         (let ([op (car asked)])
           (set! asked (cdr asked))
           (set! doing op)
           (set! doing-task runner-task)
           (set! loaded-by-op '())
           (call/cc
             (lambda (k)
               (define warned '())
               (with-exception-handler
                 (lambda (c)
                   (if (warning-only? c)
                       (set! warned (report-warning-once c warned))
                       (begin (op-how-set! op 'raised) (op-detail-set! op c) (k #f))))
                 (lambda ()
                   (op-detail-set! op (run-op op))
                   (op-how-set! op 'returned)))))
           (set! doing #f)
           (set! doing-task #f)
           (sync-top-level!)
           (op-done?-set! op #t)
           (let ([ws (op-waiters op)])
             (if (null? ws)
                 (when (eq? (op-how op) 'raised) (report-safely (op-detail op)))
                 (for-each (lambda (resume) (resume void)) ws)))
           (loop))])))

  (define (run-op op)
    (case (op-kind op)
      [(unload) (unload-with-importers! (op-target op)) (void)]
      [(finish-unload) (finish-unload! (op-target op)) (void)]
      [(load) (run-module! (op-target op)) (module-owner (op-target op))]
      [(reload) (reload! (op-target op)) (void)]
      [(exit) (exit-unloads! (op-target op))]))

  (define (op-under-way who)
    (raise (condition (make-violation) (make-who-condition who)
             (make-message-condition "an operation on modules is under way, and this code cannot wait for it"))))

  ;; A call waits, before it enters any layer, while an operation is asked
  ;; for or running, so advice on an operation sees every operation asked
  ;; for after its module loaded, its own reload included. A clean-up task,
  ;; a module body or module-loaded's advice cannot wait for it.
  (define (gate who)
    (lambda (chain)
      (rec gated
        (lambda arguments
          (cond
            [(not (on-main-thread?)) (call-on-main-thread who (lambda () (apply gated arguments)))]
            [else
             (when (body-running) (op-under-way who))
             (let wait ()
               (when (or doing (pair? asked))
                 (let ([t (current-task)])
                   (when (or (not t) (task-cleanup? t)) (op-under-way who))
                   (suspend (lambda (resume) (set! gate-waiters (cons resume gate-waiters))))
                   (wait))))
             (apply chain arguments)])))))

  ;; Modules are the main thread's state, so a thread's task asks there and
  ;; waits; what the call raises is raised in the thread, not reported on
  ;; the main thread too.
  (define (call-on-main-thread who thunk)
    (unless (current-task) (assertion-violation who "an operation is asked for from a task"))
    (let ([owner (current-owner)])
      (let-values ([(how detail)
                    (join-task
                      (spawn-task
                        (lambda (restore)
                          (call/cc
                            (lambda (k)
                              (with-exception-handler
                                (lambda (c) (if (warning-only? c) (raise-continuable c) (k (cons 'raised c))))
                                (lambda () (call-with-values thunk (lambda results (cons 'returned results))))))))))])
        (cond
          [(not (eq? how 'returned)) (raise (unloaded-condition who owner))]
          [(eq? (car (car detail)) 'raised) (raise (cdr (car detail)))]
          [else (apply values (cdr (car detail)))]))))

  ;; Code acting as an owner the operation unloads would wait for an
  ;; operation that cuts it, so it asks and returns at once.
  (define (acting-as-any? owners)
    (let ([t (current-task)])
      (and t
           (or (memq (task-owner t) owners)
               (exists (lambda (o) (task-in-code-of? t o)) owners)))))

  (define (check-may-ask who)
    (let ([t (current-task)])
      (when (and t (task-cleanup? t))
        (raise (condition (make-violation) (make-who-condition who)
                 (make-message-condition "a clean-up task cannot wait for an operation, since an unload is in progress"))))
      (unless t
        (assertion-violation who "an operation is asked for from a task"))))

  (define (importer-instances o)
    (let ([m (owner-module o)])
      (if m
          (map (lambda (name) (module-state-instance (module-of name)))
               (with-loaded-importers (list (owner-name o))))
          (list o))))

  (define (%unload-owner! o)
    (unless (owner? o) (assertion-violation 'unload-owner! "not an owner" o))
    (when (eq? (owner-kind o) 'kernel) (assertion-violation 'unload-owner! "the kernel does not unload" o))
    (unless (eq? (owner-state o) 'unloaded)
      (check-may-ask 'unload-owner!)
      (let ([op (or (find (lambda (op) (and (memq (op-kind op) '(unload finish-unload)) (eq? (op-target op) o)))
                          (if doing (cons doing asked) asked))
                    (let ([op (make-op 'unload o)]) (ask-op! op) op))])
        (unless (acting-as-any? (importer-instances o))
          (wait-op op))))
    (void))

  (define (%reload-modules! names)
    (unless (and (list? names) (for-all module-name? names))
      (assertion-violation 'reload-modules! "not a list of module names" names))
    (for-each (lambda (name)
                (unless (module-loaded? name)
                  (assertion-violation 'reload-modules! "not a loaded module" name)))
              names)
    (check-may-ask 'reload-modules!)
    (let ([op (make-op 'reload names)])
      (ask-op! op)
      (unless (acting-as-any? (map (lambda (name) (module-state-instance (module-of name)))
                                   (with-loaded-importers names)))
        (wait-op op)))
    (void))

  (define (%load-module! name)
    (unless (module-name? name) (assertion-violation 'load-module! "not a module name" name))
    (or (module-owner name)
        (begin
          (check-may-ask 'load-module!)
          (let-values ([(source object found?) (search-library 'load-module! name)])
            (unless source (assertion-violation 'load-module! "not a module" name)))
          (run-load! name)
          (or (module-owner name) (assertion-violation 'load-module! "not a module" name)))))

  ;; A load runs in the calling task, as one that an import reaches does:
  ;; its bodies cannot pause, so it is whole before any other task runs.
  (define (run-load! name)
    (set! doing (make-op 'load name))
    (set! doing-task (current-task))
    (dynamic-wind
      void
      (lambda () (install-again! (stale-modules-reached name)) (run-module! name))
      (lambda ()
        (set! doing #f)
        (set! doing-task #f)
        (sync-top-level!))))

  (define unload-owner! (kernel-define! 'unload-owner! %unload-owner! (gate 'unload-owner!)))
  (define reload-modules! (kernel-define! 'reload-modules! %reload-modules! (gate 'reload-modules!)))
  (define load-module! (kernel-define! 'load-module! %load-module! (gate 'load-module!)))

  ;;; How an owner unloads

  (define (begin-unload! o)
    (when (eq? (owner-state o) 'loaded)
      (owner-state-set! o 'unloading)
      (retarget-changed! o)
      (for-each
        (lambda (t)
          (when (and (eq? (task-owner t) o) (not (task-cleanup? t))
                     (memq (task-state t) '(running paused)))
            (unless (task-thread? t) (stop-task t))))
        (live-tasks))
      (mark-unloading-code! o)))

  (define (task-thread? t) (task-on-thread? t))

  (define (wait-until done?)
    (let loop ()
      (unless (done?)
        (suspend
          (lambda (resume)
            (let ([fired (box #f)])
              (define (fire _) (when (box-cas! fired #f #t) (resume void)))
              (add-unload-waiter! fire)
              (when (done?) (fire void)))))
        (loop))))

  (define (finish-unload! o)
    (wait-until
      (lambda ()
        (not (exists (lambda (t)
                       (and (eq? (task-kind t) 'normal)
                            (or (and (eq? (task-owner t) o) (not (task-thread? t)))
                                (task-in-code-of? t o))))
                     (live-tasks)))))
    (for-each
      (lambda (c)
        (when (eq? (change-kind c) 'unload-action)
          (forget-change! o c)
          (run-cleanup! o (change-thing c))))
      (owner-change-records o))
    (run-cleanup! o (lambda () (owner-unloading o)))
    (let ([threads (owner-threads o)])
      (for-each stop-task threads)
      (for-each (lambda (t) (join-task t)) threads))
    (owner-state-set! o 'unloaded)
    (take-back-definitions! o)
    (let ([m (owner-module o)])
      (when m
        (set-module-loaded! m #f)
        (module-state-stale?-set! m #t)
        (module-state-environment-set! m #f)
        (set! load-order (remove (owner-name o) load-order))
        (set! top-level-behind (cons (owner-name o) top-level-behind)))))

  (define (run-cleanup! o thunk)
    (let ([t (spawn-cleanup-task o (lambda (restore) (thunk)))])
      (stop-running-cleanup! t)
      (join-task t)
      (stop-running-cleanup! #f)))

  (define (unload-with-importers! o)
    (for-each
      (lambda (i)
        (unless (eq? (owner-state i) 'unloaded)
          (begin-unload! i)
          (finish-unload! i)))
      (reverse (importer-instances o))))

  (define (reload! names)
    (let* ([order (with-loaded-importers names)]
           [previous (map (lambda (name) (cons name (running-object name))) order)]
           [ranks (map (lambda (name) (cons name (module-state-rank (module-of name)))) order)])
      (for-each
        (lambda (name)
          (let ([o (module-owner name)])
            (when o (begin-unload! o) (finish-unload! o))))
        (reverse order))
      (guard (c [(not (warning-only? c)) (restore! order previous ranks) (raise c)])
        (let ([recompiled (fold-left (lambda (recompiled name) (append (reload-module-library name order) recompiled))
                                     '() names)])
          (for-each (lambda (name)
                      (if (member name recompiled)
                          (module-state-stale?-set! (module-of name) #f)
                          (load-again! name (cdr (assoc name previous)))))
                    order))
        (for-each (lambda (name) (module-state-running-object-set! (module-of name) #f)) order)
        (for-each run-module! (imports-first order))
        (for-each (lambda (name) (unless (module-loaded? name) (errorf 'reload-modules! "~s did not load" name)))
                  order))))

  (define (restore! order previous ranks)
    (for-each
      (lambda (name)
        (let ([o (module-owner name)])
          (when o (begin-unload! o) (finish-unload! o))))
      (reverse (append (remp (lambda (name) (member name order)) loaded-by-op) order)))
    (for-each
      (lambda (name)
        (let ([bytes (cdr (assoc name previous))])
          (when bytes
            (load-object! bytes)
            (module-state-running-object-set! (module-of name) bytes)
            (module-state-stale?-set! (module-of name) #f))))
      order)
    (for-each (lambda (entry) (when (cdr entry) (hashtable-set! forced-ranks (car entry) (cdr entry)))) ranks)
    (dynamic-wind
      void
      (lambda () (call-reporting (lambda () (for-each run-module! (imports-first order)))))
      (lambda () (for-each (lambda (entry) (hashtable-delete! forced-ranks (car entry))) ranks))))

  ;;; Exit's unloads

  ;; Once the stopped tasks have ended, the owners made by make-owner
  ;; unload, since one may use any module, the newest first; then each
  ;; module once no loaded module imports it.
  (define (exit-unloads! arguments)
    (wait-until
      (lambda ()
        (not (exists (lambda (t) (and (eq? (task-kind t) 'normal) (not (task-thread? t)))) (live-tasks)))))
    (for-each
      (lambda (o) (when (eq? (owner-state o) 'loaded) (begin-unload! o) (finish-unload! o)))
      (list-sort (lambda (a b) (owner<? b a)) (made-owners)))
    (let loop ()
      (let ([leaf (find (lambda (name) (null? (loaded-importers name))) load-order)])
        (when leaf
          (let ([o (module-owner leaf)])
            (begin-unload! o)
            (finish-unload! o))
          (loop))))
    (finish-exit! arguments))

  (define (install-exit-runner!)
    (set-exit-runner!
      (lambda (arguments)
        (begin-exit-unloading!)
        (stop-main-tasks! #f)
        (ask-op! (make-op 'exit arguments)))))

  ;;; Evaluating in a module

  (define (scope-environment m scope)
    (or (module-state-environment m)
        (let ([env (call-with-library-lock (lambda () (environment `(only ,(module-state-name m) ,scope))))])
          (module-state-environment-set! m env)
          env)))

  (define (own-procedure? instance symbol)
    (let ([w (definition-wrapper symbol)])
      (and w (eq? (changeable-definer w) instance))))

  (define (documentation-string body)
    (and (pair? body) (string? (car body)) (pair? (cdr body)) (car body)))

  ;; A procedure definition redefines the module's changeable procedure; a
  ;; value is an immutable variable the module's compiled code may have
  ;; folded in, so it changes only by reloading.
  (define (eval-in-module form name)
    (unless (module-name? name) (assertion-violation 'eval-in-module "not a module name" name))
    (check-main-thread 'eval-in-module)
    (let ([m (hashtable-ref modules name #f)])
      (unless (and m (module-state-loaded? m))
        (assertion-violation 'eval-in-module "not a loaded module" name))
      (let* ([instance (module-state-instance m)]
             [scope (prefixed-symbol name '%scope)]
             [env (scope-environment m scope)])
        (define (evaluate e) (call-as-owner instance (lambda () (eval (list scope e) env))))
        (let-values ([(defined expr doc) (definition-parts form)])
          (cond
            [(not defined) (evaluate form)]
            [(own-procedure? instance (prefixed-symbol name defined))
             (let ([v (evaluate expr)] [symbol (prefixed-symbol name defined)])
               (unless (procedure? v)
                 (errorf 'eval-in-module "the new value of ~s is not a procedure; values change by reloading ~s" symbol name))
               (define-changeable! instance symbol v doc)
               (void))]
            [else (errorf 'eval-in-module "~s has no procedure ~s to redefine; values and new names change by reloading" name defined)])))))

  ;; Chez names a procedure after the variable it is first bound to, so a
  ;; redefinition keeps its exported name only through this let.
  (define (definition-parts form)
    (if (and (pair? form) (eq? (car form) 'define) (pair? (cdr form)))
        (let ([head (cadr form)])
          (cond
            [(pair? head)
             (values (car head) `(lambda ,(cdr head) ,@(cddr form)) (documentation-string (cddr form)))]
            [(and (symbol? head) (pair? (cddr form)) (null? (cdddr form)))
             (values head (caddr form) #f)]
            [else (values #f #f #f)]))
        (values #f #f #f)))

  ;;; The top level

  ;; The configuration, REPLs and the plugin manager evaluate in Chez's
  ;; interaction environment on the main thread; it gets the names modules
  ;; get, a define that overrides a module's changeable procedure, and an
  ;; import that refuses Chez's replaced names and runs the bodies of the
  ;; modules it imports.
  (define top-level #f)
  (define exporters (make-eq-hashtable))
  (define imported-instances (make-hashtable equal-hash equal?))
  (define imported-exports (make-hashtable equal-hash equal?))

  (define (start-top-level!)
    (set! top-level (copy-environment (scheme-environment) #t))
    (eval '(import (tuna core replaced)) top-level)
    (define-top-level-syntax 'define top-level-define top-level)
    (define-top-level-syntax 'import top-level-import top-level)
    (interaction-environment top-level))

  (define (exported-name? symbol) (hashtable-contains? exporters symbol))

  (define (top-level-define-value symbol current value)
    (cond
      [(changeable? current) (override-set! current value)]
      [else (errorf 'define "~s is ~s's definition and cannot be defined again"
              symbol (hashtable-ref exporters symbol #f))]))

  (define (top-level-define x)
    (syntax-case x ()
      [(k (name . formals) body1 body2 ...)
       (identifier? #'name)
       #'(k name (lambda formals body1 body2 ...))]
      [(k name expr)
       (and (identifier? #'name) (exported-name? (syntax->datum #'name)))
       #'(top-level-define-value 'name name expr)]
      [(k . rest) #'(define . rest)]))

  (define (top-level-import x)
    (syntax-case x ()
      [(k spec ...)
       (let ([names (filter values (map import-spec-library (syntax->datum #'(spec ...))))])
         (for-each
           (lambda (name)
             (when (module-stale? name)
               (syntax-violation 'import (format "~s is unloaded; load it with load-module!" name) x)))
           names)
         (with-syntax ([names (datum->syntax #'k names)] [form x])
           #'(begin (import spec ...) (check-import form) (run-imported! 'names))))]))

  (define (run-imported! names)
    (run-modules! (filter (lambda (name) (hashtable-contains? found-libraries name)) names)))

  ;; A module's % procedures are not exported, so no import reaches them,
  ;; but the top level binds them, so the user can call and redefine any
  ;; helper.
  (define (private-definitions name instance)
    (let ([prefix (string-length (symbol->string (prefixed-symbol name (string->symbol ""))))])
      (filter (lambda (c)
                (and (eq? (change-kind c) 'define)
                     (let ([s (symbol->string (change-detail c))])
                       (and (fx> (string-length s) prefix) (char=? (string-ref s prefix) #\%)))))
              (owner-change-records instance))))

  (define (note-imported! name instance exports privates)
    (for-each (lambda (c) (define-top-level-value (change-detail c) (change-thing c) top-level)) privates)
    (hashtable-set! imported-instances name instance)
    (hashtable-set! imported-exports name exports)
    (for-each (lambda (symbol) (hashtable-set! exporters symbol name)) exports))

  ;; Every loaded module's names are the top level's, as a REPL expects.
  ;; Chez cannot remove a binding from an environment, so the names of an
  ;; unloaded module, and those a reloaded one no longer exports, become
  ;; keywords that raise when used, with the &unloaded that code compiled
  ;; before raises, so one handler sees both; a module loaded again is
  ;; imported again.
  (define (raising-keyword symbol message instance)
    (lambda (x)
      (raise (condition (make-unloaded instance) (make-who-condition symbol)
               (make-message-condition (format message (owner-name instance)))))))

  (define (shadow! symbol message instance)
    (hashtable-delete! exporters symbol)
    (define-top-level-syntax symbol (raising-keyword symbol message instance) top-level))

  ;; The modules loaded or unloaded since the top level last caught up,
  ;; newest first: a start that loads many modules would otherwise look
  ;; at every loaded module after each load.
  (define top-level-behind '())

  (define (sync-top-level!)
    (when (and top-level (pair? top-level-behind))
      (let ([names (reverse top-level-behind)] [seen (make-hashtable equal-hash equal?)])
        (set! top-level-behind '())
        (for-each
          (lambda (name)
            (unless (hashtable-contains? seen name)
              (hashtable-set! seen name #t)
              (sync-module! name)))
          names))))

  ;; An import here only binds names, so it is interpreted, not compiled.
  (define (sync-module! name)
    (let ([current (module-owner name)])
      (cond
        [(and current (owner-live? current))
         (let ([previous (hashtable-ref imported-instances name #f)])
           (unless (eq? current previous)
             (let* ([old (hashtable-ref imported-exports name '())]
                    [privates (private-definitions name current)]
                    [exports (append (call-with-library-lock (lambda () (library-exports name)))
                                     (map change-detail privates))])
               (for-each (lambda (symbol) (unless (memq symbol exports) (shadow! symbol "module ~s no longer defines it" previous))) old)
               (call-with-library-lock (lambda () (interpret `(import ,name) top-level)))
               (note-imported! name current exports privates))))]
        [(and (not current) (hashtable-contains? imported-instances name))
         (let ([previous (hashtable-ref imported-instances name #f)])
           (for-each (lambda (symbol) (shadow! symbol "module ~s is unloaded" previous))
                     (hashtable-ref imported-exports name '())))
         (hashtable-delete! imported-instances name)
         (hashtable-delete! imported-exports name)]))))
