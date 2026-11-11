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

  (define (entry-depth e) (car (layer-data e)))

  ;; An entry's procedure for hook-entries is made when the entry is, as
  ;; hook-entries may be called on any thread and must give the same
  ;; procedure while the entry stays.
  (define (entry-runner e) (cdr (layer-data e)))

  (define (entry<? a b)
    (let ([da (entry-depth a)] [db (entry-depth b)])
      (or (< da db)
          (and (= da db)
               (< (change-sequence (layer-change a)) (change-sequence (layer-change b)))))))

  ;; An entry whose procedure is a changeable definition of an unloaded
  ;; module would only raise, so it is skipped until the module loads
  ;; again. The entries a call runs are its layers' value, so that a call
  ;; reads one field; they are the entries in effect themselves unless some
  ;; are skipped, which tells an update whether some were. Entries that
  ;; skip some are kept here, weakly, since a collected scope's go with
  ;; it, so that a load looks only at them.
  (define skipping (make-weak-eq-hashtable))

  (define (skipped? e)
    (changeable-procedure-unloaded? (layer-value e)))

  (define (entries-updated! es before e)
    (let ([in-effect (layers-in-effect es)] [was-skipping? (not (eq? (layers-value es) before))])
      (cond
        [(and e (not was-skipping?) (not (skipped? e))) (layers-value-set! es in-effect)]
        [(exists skipped? in-effect)
         (layers-value-set! es (remp skipped? in-effect))
         (hashtable-set! skipping es #t)]
        [else
         (layers-value-set! es in-effect)
         (when was-skipping? (hashtable-delete! skipping es))])))

  (define (make-entries symbol)
    (make-procedure-layers 'hook-entry symbol entry<? entries-updated! '()))

  ;; A hook no scope has held local entries of is called without looking
  ;; at the current scope, which would add a thread parameter's read and a
  ;; scope lookup to every call.
  (define-record-type hook-state
    (nongenerative)
    (sealed #t)
    (fields symbol module key (mutable doc) (mutable global) (mutable localized?) (mutable defined?)
            (mutable procedure)))

  (define (current-entries st)
    (let ([global (layers-value (hook-state-global st))])
      (if (hook-state-localized? st)
          (let* ([s (current-scope)] [es (and s (scope-local s (hook-state-key st)))])
            (if es (merge entry<? global (layers-value es)) global))
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
                             (let* ([e (car es)] [owner (layer-owner e)])
                               (set! at es)
                               (if (eq? owner caller)
                                   (invoke (layer-value e))
                                   (dynamic-wind #t
                                     (lambda () (thread-state-owner-set! s owner))
                                     (lambda () (invoke (layer-value e)))
                                     restore-caller))
                               (loop (cdr es)))))))))))))
    (thread-state-quits-allowed-set! s #t))

  ;; An entry is a module's code, which a quit must end even where the
  ;; hook's caller lets none land, as while a change is taken back; the
  ;; handler keeps the quit from reaching the caller.
  (define (call-hook st invoke)
    (let ([entries (current-entries st)])
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

  ;; Unloading a module skips its entries in every hook, not only in those
  ;; define-hook made; held weakly, so that a dropped hook can be collected.
  (define hooks (make-weak-eq-hashtable))

  (define (make-hook symbol module doc)
    (let* ([st (make-hook-state symbol module (make-local-key) doc (make-entries symbol) #f #t #f)]
           [h (make-wrapper-procedure (hook-procedure st) -1 st)])
      (hook-state-procedure-set! st h)
      (hashtable-set! hooks st #t)
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

  (define (add-entry! who h proc depth scope)
    (let ([st (changing-hook who h)])
      (unless (procedure? proc)
        (assertion-violation who "not a procedure" proc))
      (unless (real? depth)
        (assertion-violation who "not a real number" depth))
      (let ([owner (check-current-owner who)])
        (add-layer!
          (if scope
              (scope-layers! scope (hook-state-key st)
                (lambda ()
                  (hook-state-localized?-set! st #t)
                  (make-entries (hook-state-symbol st))))
              (hook-state-global st))
          owner proc proc
          (cons depth (lambda arguments (call-as-owner owner (lambda () (apply proc arguments)))))))))

  (define (remove-entry! who h proc scope)
    (let* ([st (changing-hook who h)]
           [owner (check-current-owner who)]
           [es (if scope (scope-local scope (hook-state-key st)) (hook-state-global st))])
      (when es
        (remove-layers! es owner proc proc))))

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

  (define (forget-hook! st)
    (hook-state-defined?-set! st #f)
    (let ([es (hook-state-global st)])
      (forget-layers! es)
      (hashtable-delete! skipping es))
    (hook-state-global-set! st (make-entries (hook-state-symbol st)))
    (forget-local-layers! (hook-state-key st)))

  ;; A local entry of an unloaded module's procedure would only raise.
  (define (module-unloaded! name)
    (let-values ([(symbols states) (hashtable-entries hook-states)])
      (vector-for-each
        (lambda (symbol st)
          (when (equal? (hook-state-module st) name)
            (hashtable-delete! hook-states symbol)
            (forget-hook! st)))
        symbols states))
    (let ([states (hashtable-keys hooks)])
      (vector-for-each (lambda (st) (refresh-layers! (hook-state-global st))) states)
      (for-each
        (lambda (s)
          (vector-for-each
            (lambda (st)
              (let ([es (scope-local s (hook-state-key st))])
                (when es
                  (for-each
                    (lambda (e)
                      (when (equal? (changeable-procedure-module (layer-value e)) name)
                        (take-back! (layer-change e))))
                    (layers-all es)))))
            states))
        (scopes-with-locals))))

  (add-module-unloaded-handler! module-unloaded!)
  (add-module-loaded-handler!
    (lambda (name)
      (vector-for-each refresh-layers! (hashtable-keys skipping)))))
