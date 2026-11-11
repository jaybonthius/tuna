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
          (only (tuna core conditions) warning-only? call-with-only-handler) (only (tuna core main-thread) report-on-main-thread)
          (tuna scopes))

  (define-record-type entry
    (nongenerative)
    (sealed #t)
    (fields procedure owner depth change runner))

  (define-record-type entry-removal
    (nongenerative)
    (sealed #t)
    (fields procedure owners change))

  ;; in-effect and runnable are worked out when something changes, so a
  ;; call only reads runnable; other threads may call a hook, so each is
  ;; replaced, never changed in place.
  (define-record-type entries
    (nongenerative)
    (sealed #t)
    (fields (mutable all) (mutable removals) (mutable in-effect) (mutable runnable)))

  (define (new-entries) (make-entries '() '() '() '()))

  ;; An entry whose procedure is a changeable definition of an unloaded
  ;; module would only raise, so it is skipped until the module loads
  ;; again. Entries that skip some are kept here, weakly, since a collected
  ;; scope's go with it, so that a load looks only at them.
  (define skipping (make-weak-eq-hashtable))

  (define (skipped? e)
    (changeable-procedure-unloaded? (entry-procedure e)))

  (define (skipping? es)
    (not (eq? (entries-runnable es) (entries-in-effect es))))

  (define (set-in-effect! es in-effect)
    (let ([was-skipping? (skipping? es)])
      (entries-in-effect-set! es in-effect)
      (cond
        [(exists skipped? in-effect)
         (entries-runnable-set! es (remp skipped? in-effect))
         (hashtable-set! skipping es #t)]
        [else
         (entries-runnable-set! es in-effect)
         (when was-skipping? (hashtable-delete! skipping es))])))

  (define (change-in-effect! es in-effect e)
    (if (or (skipping? es) (skipped? e))
        (set-in-effect! es in-effect)
        (begin
          (entries-in-effect-set! es in-effect)
          (entries-runnable-set! es in-effect))))

  (define (update-runnable! es)
    (set-in-effect! es (entries-in-effect es)))

  ;; A hook no scope has held local entries of is called without looking
  ;; at the current scope, which would add a thread parameter's read and a
  ;; scope lookup to every call.
  (define-record-type hook-state
    (nongenerative)
    (sealed #t)
    (fields symbol module key (mutable doc) global (mutable localized?) (mutable defined?)
            (mutable procedure)))

  (define (entry<? a b)
    (let ([da (entry-depth a)] [db (entry-depth b)])
      (or (< da db)
          (and (= da db)
               (< (change-sequence (entry-change a)) (change-sequence (entry-change b)))))))

  (define (owned-by? owner)
    (lambda (e) (eq? (entry-owner e) owner)))

  ;; A removal hides entries by owner, not the entries it found, so that
  ;; an entry its module adds again when it reloads stays removed.
  (define (hidden? es e)
    (exists (lambda (r)
              (and (eq? (entry-removal-procedure r) (entry-procedure e))
                   (memq (entry-owner e) (entry-removal-owners r))))
            (entries-removals es)))

  (define (update! es)
    (set-in-effect! es (list-sort entry<? (remp (lambda (e) (hidden? es e)) (entries-all es)))))

  ;; Adding or taking back one entry places only that entry: sorting them
  ;; all again would cost most of the change in a hook of a few entries.
  (define (insert-entry e entries)
    (if (or (null? entries) (entry<? e (car entries)))
        (cons e entries)
        (cons (car entries) (insert-entry e (cdr entries)))))

  (define (current-entries st field)
    (let ([global (field (hook-state-global st))])
      (if (hook-state-localized? st)
          (let* ([s (current-scope)] [es (and s (scope-local s (hook-state-key st)))])
            (if es (merge entry<? global (field es)) global))
          global)))

  ;; One escape and one handler per call, not per entry, since a hook pays
  ;; for them on every call: the handler reports a raise in its dynamic
  ;; context, as call-reporting does, and the call goes on after the entry
  ;; that raised. It is the only handler, so a quit landing while it
  ;; reports ends the entry too, rather than reaching the hook's caller;
  ;; and quits wait from the escape until the next entry, which a quit
  ;; requested during the report then ends. An entry of the caller's owner
  ;; runs as a plain call; another's runs inside a critical wind that
  ;; switches the owner, so that a raise, an escape, a quit or a task's
  ;; pause and resume puts the caller's owner back.
  (define (run-entries s caller entries invoke)
    (define (restore-caller) (thread-state-owner-set! s caller))
    (let run ([entries entries])
      (unless (null? entries)
        (run (call/1cc
               (lambda (k)
                 (let ([at entries])
                   (call-with-only-handler
                     (lambda (c)
                       (report-on-main-thread c)
                       (unless (warning-only? c)
                         (thread-state-quits-allowed-set! s #f)
                         (k (cdr at))))
                     (lambda ()
                       (thread-state-quits-allowed-set! s #t)
                       (let loop ([es entries])
                         (if (null? es)
                             '()
                             (let* ([e (car es)] [owner (entry-owner e)])
                               (set! at es)
                               (if (eq? owner caller)
                                   (invoke (entry-procedure e))
                                   (dynamic-wind #t
                                     (lambda () (thread-state-owner-set! s owner))
                                     (lambda () (invoke (entry-procedure e)))
                                     restore-caller))
                               (loop (cdr es)))))))))))))
    (thread-state-quits-allowed-set! s #t))

  ;; An entry is a module's code, which a quit must end even where the
  ;; hook's caller lets none land, as while a change is taken back; the
  ;; handler keeps the quit from reaching the caller.
  (define (call-hook st invoke)
    (let ([entries (current-entries st entries-runnable)])
      (unless (null? entries)
        (let* ([s (this-thread-state)] [caller (thread-state-owner s)])
          (if (thread-state-quits-allowed s)
              (run-entries s caller entries invoke)
              (with-quits-allowed #t (run-entries s caller entries invoke)))))))

  (define (hook-procedure st)
    (case-lambda
      [() (call-hook st (lambda (p) (p)))]
      [(a) (call-hook st (lambda (p) (p a)))]
      [(a b) (call-hook st (lambda (p) (p a b)))]
      [arguments (call-hook st (lambda (p) (apply p arguments)))]))

  (define (hook? v)
    (and (wrapper-procedure? v) (hook-state? (wrapper-procedure-data v))))

  (define (hook-state-of who h)
    (let ([st (and (wrapper-procedure? h) (wrapper-procedure-data h))])
      (unless (hook-state? st)
        (assertion-violation who "not a hook" h))
      st))

  (define (changing-hook who h)
    (let ([st (hook-state-of who h)])
      (check-main-thread who)
      (unless (hook-state-defined? st)
        (raise-unloaded (hook-state-symbol st) (hook-state-module st)))
      st))

  (define (make-hook symbol module doc)
    (let* ([st (make-hook-state symbol module (make-local-key) doc (new-entries) #f #t #f)]
           [h (make-wrapper-procedure (hook-procedure st) -1 st)])
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
    (let* ([module (owner-name (current-owner))] [symbol (definition-symbol module name)])
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
      (call-as-owner owner (lambda () (apply proc arguments)))))

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
                          (hook-state-localized?-set! st #t)
                          (scope-local-set! scope (hook-state-key st) es)
                          es))
                    (hook-state-global st))])
        (unless (exists (lambda (e) (and (eq? (entry-procedure e) proc) ((owned-by? owner) e)))
                        (entries-all es))
          (with-interrupts-disabled
            (letrec* ([change (record! who 'hook-entry st proc scope
                                (lambda ()
                                  (entries-all-set! es (remq entry (entries-all es)))
                                  (change-in-effect! es (remq entry (entries-in-effect es)) entry))
                                (lambda () (update! es)))]
                      [entry (make-entry proc owner depth change (owner-runner proc owner))])
              (entries-all-set! es (cons entry (entries-all es)))
              (unless (hidden? es entry)
                (change-in-effect! es (insert-entry entry (entries-in-effect es)) entry))))))))

  ;; Each removal is a change of its own, so that an entry another module's
  ;; removal hides stays hidden while either removal stands; only the
  ;; remover's own earlier removal makes another one redundant.
  (define (removed-already? es owner proc others)
    (exists (lambda (r)
              (and (eq? (entry-removal-procedure r) proc)
                   (eq? (change-owner (entry-removal-change r)) owner)
                   (for-all (lambda (e) (memq (entry-owner e) (entry-removal-owners r))) others)))
            (entries-removals es)))

  (define (remove-entry! who h proc scope)
    (let* ([st (changing-hook who h)]
           [owner (check-current-owner who)]
           [es (if scope (scope-local scope (hook-state-key st)) (hook-state-global st))])
      (when es
        (let* ([matching (filter (lambda (e) (eq? (entry-procedure e) proc)) (entries-all es))]
               [own (filter (owned-by? owner) matching)]
               [others (remp (owned-by? owner) matching)])
          (for-each (lambda (e) (take-back! (entry-change e))) own)
          (unless (or (null? others) (removed-already? es owner proc others))
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
    (map entry-runner (current-entries (hook-state-of 'hook-entries h) entries-runnable)))

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
      (set-in-effect! es '()))
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
          (if (equal? (hook-state-module st) name)
              (begin
                (hashtable-delete! hook-states symbol)
                (forget-hook! st))
              (update-runnable! (hook-state-global st))))
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

  (add-module-unloaded-handler! module-unloaded!)
  (add-module-loaded-handler!
    (lambda (name)
      (vector-for-each update-runnable! (hashtable-keys skipping)))))
