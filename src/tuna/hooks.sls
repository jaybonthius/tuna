(library (tuna hooks)
  (export
    define-hook
    make-hook
    add-hook!
    add-local-hook!
    remove-hook!
    remove-local-hook!
    hook-entries
    hook?
    hook-documentation)
  (import (chezscheme) (tuna core changes) (tuna core definitions) (tuna core modules)
          (only (tuna core conditions) warning-only?) (only (tuna core main-thread) report-on-main-thread)
          (tuna scopes))

  (define-record-type entry
    (nongenerative)
    (sealed #t)
    (fields procedure owner depth change runner))

  (define-record-type entry-removal
    (nongenerative)
    (sealed #t)
    (fields procedure owners change))

  ;; in-effect is worked out when something changes, so a call only reads
  ;; it; other threads may call a hook, so it is replaced, never changed in
  ;; place.
  (define-record-type entries
    (nongenerative)
    (sealed #t)
    (fields (mutable all) (mutable removals) (mutable in-effect)))

  (define (new-entries) (make-entries '() '() '()))

  (define-record-type hook-state
    (nongenerative)
    (sealed #t)
    (fields symbol module key (mutable doc) global (mutable defined?) (mutable procedure)))

  (define (entry<? a b)
    (let ([da (entry-depth a)] [db (entry-depth b)])
      (or (< da db)
          (and (= da db)
               (< (change-sequence (entry-change a)) (change-sequence (entry-change b)))))))

  (define (owned-by? owner)
    (lambda (e) (equal? (entry-owner e) owner)))

  ;; A removal hides entries by owner, not the entries it found, so that
  ;; an entry its module adds again when it reloads stays removed.
  (define (hidden? es e)
    (exists (lambda (r)
              (and (eq? (entry-removal-procedure r) (entry-procedure e))
                   (member (entry-owner e) (entry-removal-owners r))))
            (entries-removals es)))

  (define (update! es)
    (entries-in-effect-set! es
      (list-sort entry<? (remp (lambda (e) (hidden? es e)) (entries-all es)))))

  (define (current-entries st)
    (let ([global (entries-in-effect (hook-state-global st))] [s (current-scope)])
      (let ([es (and s (scope-local s (hook-state-key st)))])
        (if es (merge entry<? global (entries-in-effect es)) global))))

  ;; call-reporting with one handler instead of two, since a hook pays for
  ;; it once per entry. An entry is a module's code, which a quit must end
  ;; even where the hook's caller lets none land, as while a change is
  ;; taken back; the handler keeps the quit from reaching the caller.
  (define (call-entry e arguments)
    (call/cc
      (lambda (k)
        (with-exception-handler
          (lambda (c)
            (report-on-main-thread c)
            (unless (warning-only? c) (k (void))))
          (lambda ()
            (if (quits-allowed)
                (apply (entry-procedure e) arguments)
                (parameterize ([quits-allowed #t]) (apply (entry-procedure e) arguments))))))))

  ;; An entry whose owner is already current needs no parameterize, which
  ;; costs more than the rest of the call.
  (define (call-hook st arguments)
    (let ([owner (current-owner)])
      (for-each
        (lambda (e)
          (if (equal? (entry-owner e) owner)
              (call-entry e arguments)
              (parameterize ([current-owner (entry-owner e)]) (call-entry e arguments))))
        (current-entries st)))
    (void))

  (define (hook? v)
    (and (wrapper-procedure? v) (hook-state? (wrapper-procedure-data v))))

  (define (hook-state-of who h)
    (unless (hook? h)
      (assertion-violation who "not a hook" h))
    (wrapper-procedure-data h))

  (define (changing-hook who h)
    (let ([st (hook-state-of who h)])
      (check-main-thread who)
      (unless (hook-state-defined? st)
        (raise-unloaded (hook-state-symbol st) (hook-state-module st)))
      st))

  (define (make-hook symbol module doc)
    (let* ([st (make-hook-state symbol module (make-local-key) doc (new-entries) #t #f)]
           [h (make-wrapper-procedure (lambda arguments (call-hook st arguments)) -1 st)])
      (hook-state-procedure-set! st h)
      h))

  ;; Keyed by the defined name, not the owner: the configuration and the
  ;; REPL define the same names, so either evaluating the other's form
  ;; keeps the entries.
  (define hook-states (make-eq-hashtable))

  (define (define-hook-procedure name doc)
    (check-main-thread 'define-hook)
    (unless (or (not doc) (string? doc))
      (assertion-violation 'define-hook "not a documentation string" doc))
    (let* ([module (current-owner)] [symbol (definition-symbol module name)])
      (cond
        [(hashtable-ref hook-states symbol #f)
         => (lambda (st)
              (hook-state-doc-set! st doc)
              (hook-state-procedure st))]
        [else
         (let ([h (make-hook symbol module doc)])
           (hashtable-set! hook-states symbol (wrapper-procedure-data h))
           h)])))

  (define-syntax define-hook
    (lambda (x)
      (syntax-case x ()
        [(_ id) (identifier? #'id) #'(define-hook id #f)]
        [(_ id doc) (identifier? #'id) #'(define-exported id (define-hook-procedure 'id doc))])))

  (define (record! who kind st detail scope undo reorder)
    (if scope
        (record-scope-change! scope who kind (hook-state-symbol st) detail undo reorder)
        (record-change! who kind (hook-state-symbol st) detail undo reorder)))

  (define (owner-runner proc owner)
    (lambda arguments
      (parameterize ([current-owner owner]) (apply proc arguments))))

  (define (add-entry! who h proc depth scope)
    (let ([st (changing-hook who h)])
      (unless (procedure? proc)
        (assertion-violation who "not a procedure" proc))
      (unless (real? depth)
        (assertion-violation who "not a real number" depth))
      (let ([owner (check-current-owner who)]
            [es (if scope
                    (or (scope-local scope (hook-state-key st))
                        (let ([es (new-entries)])
                          (scope-local-set! scope (hook-state-key st) es)
                          es))
                    (hook-state-global st))])
        (unless (exists (lambda (e) (and (eq? (entry-procedure e) proc) ((owned-by? owner) e)))
                        (entries-all es))
          (with-interrupts-disabled
            (letrec* ([change (record! who 'hook-entry st proc scope
                                (lambda ()
                                  (entries-all-set! es (remq entry (entries-all es)))
                                  (update! es))
                                (lambda () (update! es)))]
                      [entry (make-entry proc owner depth change (owner-runner proc owner))])
              (entries-all-set! es (cons entry (entries-all es)))
              (update! es)))))))

  (define (remove-entry! who h proc scope)
    (let* ([st (changing-hook who h)]
           [owner (check-current-owner who)]
           [es (if scope (scope-local scope (hook-state-key st)) (hook-state-global st))])
      (when es
        (let ([own (filter (lambda (e) (and (eq? (entry-procedure e) proc) ((owned-by? owner) e)))
                           (entries-all es))]
              [others (filter (lambda (e) (and (eq? (entry-procedure e) proc) (not ((owned-by? owner) e))))
                              (entries-in-effect es))])
          (for-each (lambda (e) (take-back! (entry-change e))) own)
          (unless (null? others)
            (with-interrupts-disabled
              (letrec* ([change (record! who 'removal st proc scope
                                  (lambda ()
                                    (entries-removals-set! es (remq removal (entries-removals es)))
                                    (update! es))
                                  (lambda () (update! es)))]
                        [removal (make-entry-removal proc (map entry-owner others) change)])
                (entries-removals-set! es (cons removal (entries-removals es)))
                (update! es))))))))

  (define add-hook!
    (case-lambda
      [(h proc) (add-hook! h proc 0)]
      [(h proc depth) (add-entry! 'add-hook! h proc depth #f)]))

  (define add-local-hook!
    (case-lambda
      [(h proc) (add-local-hook! h proc 0)]
      [(h proc depth)
       (add-entry! 'add-local-hook! h proc depth (the-current-scope 'add-local-hook!))]))

  (define (remove-hook! h proc)
    (remove-entry! 'remove-hook! h proc #f))

  (define (remove-local-hook! h proc)
    (remove-entry! 'remove-local-hook! h proc (the-current-scope 'remove-local-hook!)))

  (define (hook-entries h)
    (map entry-runner (current-entries (hook-state-of 'hook-entries h))))

  (define (hook-documentation h)
    (hook-state-doc (hook-state-of 'documentation h)))

  (define (entries-changes es)
    (append (map entry-change (entries-all es)) (map entry-removal-change (entries-removals es))))

  (define (forget-hook! st)
    (hook-state-defined?-set! st #f)
    (let ([es (hook-state-global st)])
      (for-each forget-change! (entries-changes es))
      (entries-all-set! es '())
      (entries-removals-set! es '())
      (entries-in-effect-set! es '()))
    (for-each
      (lambda (s)
        (let ([es (scope-local s (hook-state-key st))])
          (when es
            (for-each (lambda (c) (forget-scope-change! s c)) (entries-changes es))
            (scope-local-set! s (hook-state-key st) #f))))
      (scopes-with-locals)))

  ;; A local entry of an unloaded module's procedure would only raise.
  (define (module-unloaded! name)
    (let-values ([(symbols states) (hashtable-entries hook-states)])
      (vector-for-each
        (lambda (symbol st)
          (when (equal? (hook-state-module st) name)
            (hashtable-delete! hook-states symbol)
            (forget-hook! st)))
        symbols states))
    (let ([states (hashtable-values hook-states)])
      (for-each
        (lambda (s)
          (vector-for-each
            (lambda (st)
              (let ([es (scope-local s (hook-state-key st))])
                (when es
                  (for-each
                    (lambda (e)
                      (when (equal? (changeable-procedure-module (entry-procedure e)) name)
                        (take-back! (entry-change e))))
                    (entries-all es)))))
            states))
        (scopes-with-locals))))

  (add-module-unloaded-handler! module-unloaded!))
