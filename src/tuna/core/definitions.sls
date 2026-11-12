(library (tuna core definitions)
  (export
    define-public
    define-exported
    module-property
    site-module
    advice-add!
    advice-remove!
    remove-override!
    definition-changes
    report
    report-safely
    report-warning
    report-warning-once
    call-with-warnings-reported
    call-reporting
    call-module-code
    tick
    tick-changed?
    batch-ended
    batch-ended-changed?
    module-loaded
    module-failed
    module-definitions-started!
    unload-removed-definitions!
    unload-definitions!
    raise-unloaded
    raise-removed
    changeable-symbol?
    changeable-symbol-module
    changeable-identifier?
    changeable-procedure-module
    changeable-procedure-unloaded?
    changeable-procedure-documentation
    set-changeable-documentation!)
  (import (chezscheme) (tuna core changes) (tuna core conditions)
          (only (chez-lang body) unbound-identifier?))

  ;; Through this property of a module's own this-module keyword, a macro
  ;; learns which module the code it expands belongs to.
  (define module-property)

  (define cell-property)

  ;; value and callee are worked out when something changes, so a call
  ;; costs one field read. The override and advice in effect are worked out
  ;; only on the main thread, which alone changes owners' ranks, so a
  ;; module's own assignment on another thread just rebuilds value and
  ;; callee from them.
  (define-record-type cell
    (nongenerative)
    (sealed #t)
    (fields module symbol forwarder overrides advice
            (mutable definition)
            (mutable doc)
            (mutable defined)
            (mutable state)
            (mutable redefined?)
            (mutable value)
            (mutable callee)
            (mutable advised))
    (protocol
      (lambda (new)
        (lambda (module symbol)
          (letrec* ([c (new module symbol
                         (make-wrapper-procedure (lambda arguments (apply (cell-callee c) arguments)) -1 #f)
                         (make-value-layers 'override symbol layer-after?
                           (lambda (ls before l) (overrides-updated! c ls)) #f)
                         (make-procedure-layers 'advice symbol layer-after?
                           (lambda (ls before l) (advice-updated! c ls)) '())
                         #f #f #f 'loaded #t #f #f '())])
            (set-wrapper-procedure-data! (cell-forwarder c) c)
            c)))))

  ;; A cell outlives its module's instance, so a procedure a name gave and
  ;; the changes made to it survive the module running its body again.
  (define cells (make-eq-hashtable))
  (define module-cells (make-hashtable equal-hash equal?))

  ;; Changes are made on the main thread only, but a module assigns its own
  ;; definitions from any thread; each cell update is done whole under it.
  ;; The timer interrupt runs tick's advice, which may change definitions
  ;; too, so an update also runs with interrupts disabled. The mutex is
  ;; taken first: a thread with interrupts disabled waits for a mutex
  ;; without letting a collection run, and the holder may be waiting for
  ;; one.
  (define cells-mutex (make-mutex))

  (define-syntax with-cells-locked
    (syntax-rules ()
      [(_ e1 e2 ...) (with-quit-safe-mutex cells-mutex (with-interrupts-disabled e1 e2 ...))]))

  (define (cell-loaded? c)
    (eq? (cell-state c) 'loaded))

  (define (loaded-cell symbol)
    (let ([c (hashtable-ref cells symbol #f)])
      (and c (cell-loaded? c) c)))

  (define (changeable-symbol? symbol)
    (and (loaded-cell symbol) #t))

  (define (changeable-symbol-module symbol)
    (let ([c (loaded-cell symbol)])
      (and c (cell-module c))))

  (define (forwarder-cell p)
    (and (wrapper-procedure? p)
         (let ([c (wrapper-procedure-data p)])
           (and (cell? c) c))))

  (define (changeable-procedure-module p)
    (let ([c (forwarder-cell p)])
      (and c (cell-module c))))

  (define (changeable-procedure-unloaded? p)
    (let ([c (forwarder-cell p)])
      (and c (eq? (cell-state c) 'unloaded))))

  (define (changeable-procedure-documentation p)
    (let ([c (forwarder-cell p)])
      (and c (cell-doc c))))

  (define (set-changeable-documentation! symbol doc)
    (cell-doc-set! (hashtable-ref cells symbol #f) doc))

  (define (raise-not-loaded who message)
    (raise (condition (make-violation) (make-who-condition who) (make-message-condition message))))

  (define (raise-unloaded who module)
    (raise-not-loaded who (format "module ~s is unloaded" module)))

  (define (raise-removed who module)
    (raise-not-loaded who (format "module ~s no longer defines it" module)))

  (define (raise-cell-not-loaded c)
    ((if (eq? (cell-state c) 'removed) raise-removed raise-unloaded) (cell-symbol c) (cell-module c)))

  (define (rebuild! c)
    (if (cell-loaded? c)
        (let ([value (let ([override (layers-value (cell-overrides c))])
                       (if override (layer-value override) (cell-definition c)))])
          (cell-value-set! c value)
          (cell-callee-set! c
            (fold-right
              (lambda (advice inner) (lambda arguments (apply advice inner arguments)))
              value
              (layers-value (cell-advice c)))))
        (cell-callee-set! c (lambda arguments (raise-cell-not-loaded c)))))

  ;; The definition is a change too, so an override is in effect only if
  ;; it comes after the definition in the order of changes.
  (define (overrides-updated! c ls)
    (with-cells-locked
      (layers-value-set! ls
        (let ([in-effect (layers-in-effect ls)])
          (and (pair? in-effect)
               (>= (owner-rank (layer-owner (car in-effect))) (owner-rank (find-owner (cell-module c))))
               (car in-effect))))
      (rebuild! c)))

  ;; Advice that is an unloaded module's changeable procedure would only
  ;; raise, so it is left out while that module is unloaded.
  (define (advice-updated! c ls)
    (with-cells-locked
      (layers-value-set! ls
        (map layer-value
             (remp (lambda (l) (changeable-procedure-unloaded? (layer-value l)))
                   (layers-in-effect ls))))
      (rebuild! c)))

  (define (update-advised! c)
    (for-each (lambda (advised) (refresh-layers! (cell-advice advised))) (cell-advised c)))

  (define (check-loaded c)
    (unless (cell-loaded? c)
      (raise-cell-not-loaded c)))

  (define (cell-reference c)
    (check-loaded c)
    (let ([v (cell-value c)])
      (if (procedure? v) (cell-forwarder c) v)))

  (define (define-cell! symbol module value doc)
    (with-cells-locked
      (let ([c (or (hashtable-ref cells symbol #f)
                   (let ([c (make-cell module symbol)])
                     (hashtable-set! cells symbol c)
                     (hashtable-update! module-cells module (lambda (cs) (cons c cs)) '())
                     c))])
        (cell-redefined?-set! c #t)
        (let ([unloaded? (eq? (cell-state c) 'unloaded)])
          (cell-state-set! c 'loaded)
          (cell-definition-set! c value)
          (cell-doc-set! c doc)
          (refresh-layers! (cell-overrides c))
          (when unloaded? (update-advised! c)))
        (unless (cell-defined c)
          (cell-defined-set! c
            (record-definition! module symbol (lambda () (refresh-layers! (cell-overrides c))))))
        c)))

  (define (cell-assign! c v)
    (with-cells-locked
      (cell-definition-set! c v)
      (rebuild! c)))

  ;; Adding and removing layers update the cell with interrupts disabled,
  ;; where waiting for the mutex is unsafe, so they take it before.
  (define (cell-override! c v)
    (let ([owner (current-owner-record)])
      (cond
        [(equal? (owner-name owner) (cell-module c)) (cell-assign! c v)]
        [else
         (check-main-thread 'set!)
         (check-current-owner 'set!)
         (check-loaded c)
         (with-cells-locked (add-layer! (cell-overrides c) owner #f v))])))

  (define (cell-advise! c advice)
    (check-main-thread 'advice-add!)
    (check-loaded c)
    (unless (procedure? advice)
      (assertion-violation 'advice-add! "not a procedure" advice))
    (let ([owner (check-current-owner 'advice-add!)] [advice-cell (forwarder-cell advice)])
      (with-cells-locked
        (when (and advice-cell (not (memq c (cell-advised advice-cell))))
          (cell-advised-set! advice-cell (cons c (cell-advised advice-cell))))
        (add-layer! (cell-advice c) owner advice advice))))

  (define (cell-unadvise! c advice)
    (check-main-thread 'advice-remove!)
    (check-loaded c)
    (let ([owner (check-current-owner 'advice-remove!)])
      (with-cells-locked (remove-layers! (cell-advice c) owner advice advice))))

  (define (cell-unoverride! c)
    (check-main-thread 'remove-override!)
    (check-loaded c)
    (let ([owner (check-current-owner 'remove-override!)])
      (with-cells-locked (remove-layers! (cell-overrides c) owner #f #f))))

  (define (cell-change-list c)
    (let ([changes (append (layers-changes (cell-overrides c)) (layers-changes (cell-advice c)))])
      (if (cell-defined c) (cons (cell-defined c) changes) changes)))

  ;; The cells stay, so that a procedure a name gave raises rather than runs
  ;; stale code, and works again when the module defines the name again.
  (define (unload-cell! c state)
    (for-each take-back! (cell-change-list c))
    (with-cells-locked
      (cell-defined-set! c #f)
      (cell-state-set! c state)
      (rebuild! c))
    (update-advised! c))

  (define (unload-definitions! module)
    (for-each (lambda (c) (unload-cell! c 'unloaded)) (hashtable-ref module-cells module '())))

  (define (module-definitions-started! module)
    (for-each (lambda (c) (cell-redefined?-set! c #f)) (hashtable-ref module-cells module '())))

  ;; Once a module is recompiled, Chez refuses code bound to its previous
  ;; instance, so a name the running instance no longer defines cannot be
  ;; kept working; it goes with its changes, as on unload.
  (define (unload-removed-definitions! module)
    (for-each
      (lambda (c)
        (unless (or (cell-redefined? c) (eq? (cell-state c) 'removed))
          (unload-cell! c 'removed)))
      (hashtable-ref module-cells module '())))

  (define (cell-changes c)
    (map (lambda (change)
           (list (owner-name (change-owner change)) (change-kind change)
                 (and (memq (change-kind change) '(advice removal)) (change-detail change))))
         (list-sort (lambda (a b) (> (change-sequence a) (change-sequence b))) (cell-change-list c))))

  (define (changeable-identifier? id lookup)
    (and (lookup id #'cell-property) #t))

  (meta define (site-module id lookup)
    (let ([probe (datum->syntax id 'this-module)])
      (and (not (unbound-identifier? probe))
           (lookup probe #'module-property))))

  (meta define (identifier-cell who x id lookup)
    (or (and (identifier? id)
             (not (unbound-identifier? id))
             (let ([definition (lookup id #'cell-property)])
               (and definition (car definition))))
        (syntax-violation who "not a changeable definition" x id)))

  ;; Every changeable definition's keyword is this one transformer, which
  ;; finds the definition's cell and module through the keyword's
  ;; property, so a module's object file holds no transformer of its own.
  (meta define changeable-keyword
    (make-variable-transformer
      (lambda (x)
        (lambda (lookup)
          (define (definition id) (lookup id #'cell-property))
          (syntax-case x ()
            [(s id v)
             (and (identifier? #'s) (free-identifier=? #'s #'set!))
             (let ([d (definition #'id)])
               (if (equal? (site-module #'id lookup) (cdr d))
                   #`(cell-assign! #,(car d) v)
                   #`(cell-override! #,(car d) v)))]
            [(k argument ...) #`((cell-callee #,(car (definition #'k))) argument ...)]
            [k (identifier? #'k) #`(cell-reference #,(car (definition #'k)))])))))

  (define-syntax define-changeable
    (syntax-rules ()
      [(_ name cell module symbol expr doc)
       (begin
         (define-syntax name changeable-keyword)
         (define-property name cell-property (cons #'cell 'module))
         (define cell (define-cell! 'symbol 'module expr doc)))]))

  ;; Chez names a procedure after the variable it is bound to, and the
  ;; value goes to the cell as an argument, so it is bound first to a
  ;; variable named with the exported name: an error or a stack sample
  ;; then says which module's definition it is.
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
                                 [(cell) (generate-temporaries '(cell))]
                                 [symbol (datum->syntax name (prefixed-symbol module (syntax->datum name)))])
                     #'(begin
                         (define-changeable name cell module symbol (let ([symbol expr]) symbol) doc)
                         (export (rename (name symbol)))))
                   #'(define head body ...))))]))))

  (define-syntax define-exported
    (lambda (x)
      (lambda (lookup)
        (syntax-case x ()
          [(_ name expr)
           (identifier? #'name)
           (let ([module (site-module #'name lookup)])
             (if module
                 (with-syntax ([symbol (datum->syntax #'name (prefixed-symbol module (syntax->datum #'name)))])
                   #'(begin (define name expr) (export (rename (name symbol)))))
                 #'(define name expr)))]))))

  (define-syntax advice-add!
    (lambda (x)
      (lambda (lookup)
        (syntax-case x ()
          [(_ id proc) #`(cell-advise! #,(identifier-cell 'advice-add! x #'id lookup) proc)]))))

  (define-syntax advice-remove!
    (lambda (x)
      (lambda (lookup)
        (syntax-case x ()
          [(_ id proc) #`(cell-unadvise! #,(identifier-cell 'advice-remove! x #'id lookup) proc)]))))

  (define-syntax remove-override!
    (lambda (x)
      (lambda (lookup)
        (syntax-case x ()
          [(_ id) #`(cell-unoverride! #,(identifier-cell 'remove-override! x #'id lookup))]))))

  (define-syntax definition-changes
    (lambda (x)
      (lambda (lookup)
        (syntax-case x ()
          [(_ id) #`(cell-changes #,(identifier-cell 'definition-changes x #'id lookup))]))))

  ;; Every report runs as the module the raising code ran for, a job's
  ;; included, so the current owner names it.
  (define (write-report c)
    (let ([name (current-owner)])
      (write-condition c (and (not (member name '((init) (repl) (tuna)))) name))))

  (define-changeable report report-cell (tuna) report write-report #f)

  (define (report-safely c)
    (guard (e [#t (write-report c) (write-report e)])
      (report c)))

  (define (report-warning who text)
    (report-safely (condition (make-warning) (make-who-condition who) (make-message-condition text))))

  ;; Chez runs its source optimizer twice, so one compile warning can be
  ;; raised twice; a warning whose text was reported already is not
  ;; reported again.
  (define (report-warning-once c reported)
    (let ([text (condition-text c)])
      (if (member text reported)
          reported
          (begin (report-safely c) (cons text reported)))))

  (define (call-with-warnings-reported thunk)
    (let ([reported '()])
      (with-exception-handler
        (lambda (c)
          (if (warning-only? c)
              (set! reported (report-warning-once c reported))
              (raise-continuable c)))
        thunk)))

  ;; A raise is reported in its own dynamic context, before anything
  ;; unwinds, so that advice on report can inspect it there.
  (define (call-reporting thunk)
    (call/cc
      (lambda (k)
        (call-with-only-handler
          (lambda (c) (report-safely c) (k (void)))
          (lambda () (call-with-warnings-reported thunk))))))

  ;; Bookkeeping, where quits wait, runs a module's code through this, so
  ;; that a quit ends that code alone and the bookkeeping goes on.
  (define (call-module-code thunk)
    (call-reporting (lambda () (with-quits-allowed #t (thunk)))))

  (define (do-nothing) (void))

  (define-changeable tick tick-cell (tuna) tick do-nothing #f)

  ;; The main thread calls tick about every thousand procedure calls; an
  ;; unchanged tick does nothing, so it need not be called at all.
  (define (tick-changed?)
    (not (eq? (cell-callee tick-cell) do-nothing)))

  (define-changeable batch-ended batch-ended-cell (tuna) batch-ended do-nothing #f)

  (define (batch-ended-changed?)
    (not (eq? (cell-callee batch-ended-cell) do-nothing)))

  (define-changeable module-loaded module-loaded-cell (tuna) module-loaded (lambda (name) (void)) #f)

  (define-changeable module-failed module-failed-cell (tuna) module-failed (lambda (name) (void)) #f))
