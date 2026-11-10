(library (tuna tables)
  (export
    define-table
    table-set!
    table-remove!
    table-ref
    table-entries
    table-owner
    table?
    table-documentation)
  (import (chezscheme) (tuna core changes) (tuna core definitions) (tuna core modules))

  (define-record-type layer
    (nongenerative)
    (sealed #t)
    (fields owner value change))

  (define-record-type key-removal
    (nongenerative)
    (sealed #t)
    (fields owners change))

  (define-record-type key-state
    (nongenerative)
    (sealed #t)
    (fields (mutable layers) (mutable removals) (mutable in-effect)))

  ;; Only the main thread changes a table. It reads without the mutex;
  ;; other threads take it, since a hashtable read while another thread
  ;; adds to it can see it half changed.
  (define-record-type (table new-table table?)
    (nongenerative)
    (sealed #t)
    (fields symbol module (mutable doc)
            (mutable symbol-keys) (mutable eqv-keys) (mutable string-keys) (mutable equal-keys)
            (mutable order) mutex (mutable defined?)))

  ;; An equal-hash lookup costs several times a symbol, eqv or string one,
  ;; so keys whose equal? is eq?, eqv? or string=? have hashtables of their
  ;; own, each made when the first key of its kind is stored; make? is true
  ;; only on the main thread, holding the table's mutex. A macro, so that a
  ;; lookup carries no code for making one.
  (define-syntax key-table
    (syntax-rules ()
      [(_ t key make?)
       (let-syntax ([kind (syntax-rules ()
                            [(_ keys keys-set! make-keys)
                             (or (keys t) (and make? (let ([new make-keys]) (keys-set! t new) new)))])])
         (cond
           [(symbol? key) (kind table-symbol-keys table-symbol-keys-set! (make-hashtable symbol-hash eq?))]
           [(or (fixnum? key) (char? key) (boolean? key))
            (kind table-eqv-keys table-eqv-keys-set! (make-eqv-hashtable))]
           [(string? key) (kind table-string-keys table-string-keys-set! (make-hashtable string-hash string=?))]
           [else (kind table-equal-keys table-equal-keys-set! (make-hashtable equal-hash equal?))]))]))

  (define (key-tables t)
    (filter values (list (table-symbol-keys t) (table-eqv-keys t) (table-string-keys t) (table-equal-keys t))))

  (define (find-key-state t key)
    (let ([keys (key-table t key #f)])
      (and keys (hashtable-ref keys key #f))))

  (define-syntax with-table-read
    (syntax-rules ()
      [(_ t e1 e2 ...)
       (if (on-main-thread?)
           (begin e1 e2 ...)
           (with-mutex (table-mutex t) e1 e2 ...))]))

  (define (table-of who t)
    (unless (table? t)
      (assertion-violation who "not a table" t))
    t)

  (define (changing-table who t)
    (table-of who t)
    (check-main-thread who)
    (unless (table-defined? t)
      (raise-unloaded (table-symbol t) (table-module t)))
    t)

  ;; Keyed by the defined name, not the owner: the configuration and the
  ;; REPL define the same names, so either evaluating the other's form
  ;; keeps the entries.
  (define tables (make-eq-hashtable))

  (define (make-table name doc)
    (check-main-thread 'define-table)
    (unless (or (not doc) (string? doc))
      (assertion-violation 'define-table "not a documentation string" doc))
    (let* ([module (owner-name (current-owner))] [symbol (definition-symbol module name)])
      (cond
        [(hashtable-ref tables symbol #f)
         => (lambda (t) (table-doc-set! t doc) t)]
        [else
         (let ([t (new-table symbol module doc #f #f #f #f '() (make-mutex) #t)])
           (hashtable-set! tables symbol t)
           t)])))

  (define-syntax define-table
    (lambda (x)
      (syntax-case x ()
        [(_ id) (identifier? #'id) #'(define-table id #f)]
        [(_ id doc) (identifier? #'id) #'(define-exported id (make-table 'id doc))])))

  (define (layer>? a b)
    (> (owner-rank (layer-owner a)) (owner-rank (layer-owner b))))

  ;; A removal hides values by owner, not the values it found, so that a
  ;; value its module sets again when it reloads stays removed.
  (define (hidden? ks l)
    (exists (lambda (r) (memq (layer-owner l) (key-removal-owners r))) (key-state-removals ks)))

  (define (update! ks)
    (key-state-in-effect-set! ks
      (list-sort layer>? (remp (lambda (l) (hidden? ks l)) (key-state-layers ks)))))

  (define (existing-key-state t key)
    (with-table-read t (find-key-state t key)))

  (define (key-state-for! t key)
    (or (find-key-state t key)
        (let ([ks (make-key-state '() '() '())])
          (with-quit-safe-mutex (table-mutex t)
            (hashtable-set! (key-table t key #t) key ks))
          (table-order-set! t (cons key (table-order t)))
          ks)))

  (define (owned-by? owner)
    (lambda (l) (eq? (layer-owner l) owner)))

  (define table-set!
    (case-lambda
      [(t key) (table-set! t key #t)]
      [(t key v)
       (changing-table 'table-set! t)
       (let* ([owner (check-current-owner 'table-set!)] [ks (key-state-for! t key)])
         (with-interrupts-disabled
           (let ([previous (find (owned-by? owner) (key-state-layers ks))])
             (when previous
               (forget-change! (layer-change previous))
               (key-state-layers-set! ks (remq previous (key-state-layers ks)))))
           (letrec* ([change (record-change! 'table-set! 'table-entry (table-symbol t) key
                               (lambda ()
                                 (key-state-layers-set! ks (remq layer (key-state-layers ks)))
                                 (update! ks))
                               (lambda () (update! ks)))]
                     [layer (make-layer owner v change)])
             (key-state-layers-set! ks (cons layer (key-state-layers ks)))
             (update! ks))))]))

  (define (table-remove! t key)
    (changing-table 'table-remove! t)
    (let ([owner (check-current-owner 'table-remove!)] [ks (existing-key-state t key)])
      (when ks
        (let ([own (find (owned-by? owner) (key-state-layers ks))]
              [others (remp (owned-by? owner) (key-state-in-effect ks))])
          (when own (take-back! (layer-change own)))
          (unless (null? others)
            (with-interrupts-disabled
              (letrec* ([change (record-change! 'table-remove! 'removal (table-symbol t) key
                                  (lambda ()
                                    (key-state-removals-set! ks (remq removal (key-state-removals ks)))
                                    (update! ks))
                                  (lambda () (update! ks)))]
                        [removal (make-key-removal (map layer-owner others) change)])
                (key-state-removals-set! ks (cons removal (key-state-removals ks)))
                (update! ks))))))))

  (define (in-effect ks)
    (and ks (pair? (key-state-in-effect ks)) (car (key-state-in-effect ks))))

  (define table-ref
    (case-lambda
      [(t key) (table-ref t key #f)]
      [(t key default)
       (let ([l (in-effect (existing-key-state (table-of 'table-ref t) key))])
         (if l (layer-value l) default))]))

  (define (table-owner t key)
    (let ([l (in-effect (existing-key-state (table-of 'table-owner t) key))])
      (and l (owner-name (layer-owner l)))))

  (define (table-entries t)
    (table-of 'table-entries t)
    (with-table-read t
      (fold-left
        (lambda (entries key)
          (let ([l (in-effect (find-key-state t key))])
            (if l (cons (cons key (layer-value l)) entries) entries)))
        '()
        (table-order t))))

  (define (table-documentation t)
    (table-doc (table-of 'documentation t)))

  (define (module-unloaded! name)
    (let-values ([(symbols ts) (hashtable-entries tables)])
      (vector-for-each
        (lambda (symbol t)
          (when (equal? (table-module t) name)
            (hashtable-delete! tables symbol)
            (table-defined?-set! t #f)
            (for-each
              (lambda (keys)
                (vector-for-each
                  (lambda (ks)
                    (for-each (lambda (l) (forget-change! (layer-change l))) (key-state-layers ks))
                    (for-each (lambda (r) (forget-change! (key-removal-change r))) (key-state-removals ks)))
                  (hashtable-values keys)))
              (key-tables t))
            (with-quit-safe-mutex (table-mutex t)
              (for-each hashtable-clear! (key-tables t)))
            (table-order-set! t '())))
        symbols ts)))

  (add-module-unloaded-handler! module-unloaded!))
