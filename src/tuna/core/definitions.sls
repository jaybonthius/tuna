(library (tuna core definitions)
  (export
    define-public
    module-property
    advice-add!
    advice-remove!
    definition-changes
    report
    module-loaded
    changeable-symbol?
    changeable-symbol-module
    changeable-identifier?)
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
    (fields module symbol forwarder
            (mutable definition)
            (mutable doc)
            (mutable overrides)
            (mutable advice)
            (mutable removals)
            (mutable history)
            (mutable override-in-effect)
            (mutable advice-in-effect)
            (mutable value)
            (mutable callee))
    (protocol
      (lambda (new)
        (lambda (module symbol)
          (letrec ([c (new module symbol
                        (lambda arguments (apply (cell-callee c) arguments))
                        #f #f '() '() '() '() #f '() #f #f)])
            c)))))

  (define-record-type layer
    (nongenerative)
    (sealed #t)
    (fields change value))

  (define-record-type removal
    (nongenerative)
    (sealed #t)
    (fields change procedure owners))

  ;; A cell outlives its module's instance, so a procedure a name gave and
  ;; the changes made to it survive the module running its body again.
  (define cells (make-eq-hashtable))

  ;; Changes are made on the main thread only, but a module assigns its own
  ;; definitions from any thread; each cell update is done whole under it.
  (define cells-mutex (make-mutex))

  (define (changeable-symbol? symbol)
    (hashtable-contains? cells symbol))

  (define (changeable-symbol-module symbol)
    (let ([c (hashtable-ref cells symbol #f)])
      (and c (cell-module c))))

  (define (layer<? a b)
    (let ([ca (layer-change a)] [cb (layer-change b)])
      (let ([ra (owner-rank (change-owner ca))] [rb (owner-rank (change-owner cb))])
        (or (< ra rb)
            (and (= ra rb) (< (change-sequence ca) (change-sequence cb)))))))

  (define (hidden? c layer)
    (exists (lambda (removal)
              (and (eq? (removal-procedure removal) (layer-value layer))
                   (member (change-owner (layer-change layer)) (removal-owners removal))))
            (cell-removals c)))

  (define (rebuild! c)
    (let ([value (let ([override (cell-override-in-effect c)])
                   (if override (layer-value override) (cell-definition c)))])
      (cell-value-set! c value)
      (cell-callee-set! c
        (fold-left
          (lambda (inner advice) (lambda arguments (apply advice inner arguments)))
          value
          (cell-advice-in-effect c)))))

  (define (choose-in-effect! c)
    (let ([override (and (pair? (cell-overrides c))
                         (car (last-pair (list-sort layer<? (cell-overrides c)))))])
      (cell-override-in-effect-set! c
        (and override
             (>= (owner-rank (change-owner (layer-change override)))
                 (owner-rank (cell-module c)))
             override))
      (cell-advice-in-effect-set! c
        (map layer-value (list-sort layer<? (remp (lambda (layer) (hidden? c layer)) (cell-advice c)))))
      (rebuild! c)))

  (define-syntax with-cell-update
    (syntax-rules ()
      [(_ c e ...) (with-mutex cells-mutex e ... (choose-in-effect! c))]))

  (define (cell-reference c)
    (let ([v (cell-value c)])
      (if (procedure? v) (cell-forwarder c) v)))

  (define (define-cell! symbol module value doc)
    (check-main-thread 'define)
    (let ([c (or (hashtable-ref cells symbol #f)
                 (let ([c (make-cell module symbol)])
                   (hashtable-set! cells symbol c)
                   c))])
      (with-cell-update c
        (cell-definition-set! c value)
        (cell-doc-set! c doc))
      (when (null? (cell-history c))
        (let ([change (parameterize ([current-owner module])
                        (record-change! 'define 'define symbol #f void void))])
          (cell-history-set! c (list change))))
      c))

  (define (cell-assign! c v)
    (with-mutex cells-mutex
      (cell-definition-set! c v)
      (rebuild! c)))

  (define (add-history! c change)
    (cell-history-set! c (cons change (cell-history c))))

  (define (drop-history! c change)
    (cell-history-set! c (remq change (cell-history c))))

  (define (reorder c)
    (lambda () (with-cell-update c)))

  (define (cell-override! c v)
    (let ([owner (current-owner)])
      (cond
        [(equal? owner (cell-module c)) (cell-assign! c v)]
        [else
         (check-main-thread 'set!)
         (let ([previous (find (lambda (layer) (equal? (change-owner (layer-change layer)) owner))
                               (cell-overrides c))])
           (when previous (take-back! (layer-change previous))))
         (letrec ([layer
                   (make-layer
                     (record-change! 'set! 'override (cell-symbol c) #f
                       (lambda ()
                         (with-cell-update c
                           (cell-overrides-set! c (remq layer (cell-overrides c)))
                           (drop-history! c (layer-change layer))))
                       (reorder c))
                     v)])
           (with-cell-update c
             (cell-overrides-set! c (cons layer (cell-overrides c)))
             (add-history! c (layer-change layer))))])))

  (define (cell-advise! c advice)
    (check-main-thread 'advice-add!)
    (unless (procedure? advice)
      (assertion-violation 'advice-add! "not a procedure" advice))
    (let ([owner (current-owner)])
      (unless (exists (lambda (layer)
                        (and (eq? (layer-value layer) advice)
                             (equal? (change-owner (layer-change layer)) owner)))
                      (cell-advice c))
        (letrec ([layer
                  (make-layer
                    (record-change! 'advice-add! 'advice (cell-symbol c) advice
                      (lambda ()
                        (with-cell-update c
                          (cell-advice-set! c (remq layer (cell-advice c)))
                          (drop-history! c (layer-change layer))))
                      (reorder c))
                    advice)])
          (with-cell-update c
            (cell-advice-set! c (cons layer (cell-advice c)))
            (add-history! c (layer-change layer)))))))

  ;; Removing another module's advice hides it, and keeps hiding what that
  ;; module adds again, until the remover's change is taken back.
  (define (cell-unadvise! c advice)
    (check-main-thread 'advice-remove!)
    (let* ([owner (current-owner)]
           [visible (remp (lambda (layer) (hidden? c layer)) (cell-advice c))]
           [matching (filter (lambda (layer) (eq? (layer-value layer) advice)) visible)]
           [own (filter (lambda (layer) (equal? (change-owner (layer-change layer)) owner)) matching)]
           [others (remp (lambda (layer) (memq layer own)) matching)])
      (for-each (lambda (layer) (take-back! (layer-change layer))) own)
      (unless (null? others)
        (letrec ([removal
                  (make-removal
                    (record-change! 'advice-remove! 'removal (cell-symbol c) advice
                      (lambda ()
                        (with-cell-update c
                          (cell-removals-set! c (remq removal (cell-removals c)))
                          (drop-history! c (removal-change removal))))
                      (reorder c))
                    advice
                    (map (lambda (layer) (change-owner (layer-change layer))) others))])
          (with-cell-update c
            (cell-removals-set! c (cons removal (cell-removals c)))
            (add-history! c (removal-change removal)))))))

  (define (cell-changes c)
    (map (lambda (change)
           (list (change-owner change) (change-kind change)
                 (and (memq (change-kind change) '(advice removal)) (change-detail change))))
         (cell-history c)))

  (define (changeable-identifier? id lookup)
    (and (lookup id #'cell-property) #t))

  (meta define (site-module id lookup)
    (let ([probe (datum->syntax id 'this-module)])
      (and (not (unbound-identifier? probe))
           (lookup probe #'module-property))))

  (meta define (identifier-cell who x id lookup)
    (or (and (identifier? id)
             (not (unbound-identifier? id))
             (lookup id #'cell-property))
        (syntax-violation who "not a changeable definition" x id)))

  ;; Every changeable definition's keyword is made by this one procedure,
  ;; so a module's object file holds a call to it, not a transformer of its
  ;; own.
  (meta define (changeable-transformer cell module)
    (make-variable-transformer
      (lambda (x)
        (lambda (lookup)
          (syntax-case x ()
            [(s id v)
             (and (identifier? #'s) (free-identifier=? #'s #'set!))
             (if (equal? (site-module #'id lookup) module)
                 #`(cell-assign! #,cell v)
                 #`(cell-override! #,cell v))]
            [(_ argument ...) #`((cell-callee #,cell) argument ...)]
            [_ (identifier? x) #`(cell-reference #,cell)])))))

  (define-syntax define-changeable
    (syntax-rules ()
      [(_ name module symbol expr doc)
       (begin
         (define-syntax name (changeable-transformer #'cell 'module))
         (define-property name cell-property #'cell)
         (define cell (define-cell! 'symbol 'module expr doc)))]))

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
                     #'(begin
                         (define-changeable name module symbol expr doc)
                         (export (rename (name symbol)))))
                   #'(define head body ...))))]))))

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

  (define-syntax definition-changes
    (lambda (x)
      (lambda (lookup)
        (syntax-case x ()
          [(_ id) #`(cell-changes #,(identifier-cell 'definition-changes x #'id lookup))]))))

  (define-changeable report (tuna) report write-condition #f)

  (define-changeable module-loaded (tuna) module-loaded (lambda (name) (void)) #f))
