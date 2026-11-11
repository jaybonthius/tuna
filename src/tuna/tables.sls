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
  (import (chezscheme) (tuna core changes) (tuna core definitions) (tuna registry))

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

  (define (find-key-layers t key)
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

  (define (forget-table! t)
    (table-defined?-set! t #f)
    (for-each (lambda (keys) (vector-for-each forget-layers! (hashtable-values keys))) (key-tables t))
    (with-quit-safe-mutex (table-mutex t)
      (for-each hashtable-clear! (key-tables t)))
    (table-order-set! t '()))

  (define tables (make-registry table-module forget-table!))

  (define (make-table name doc)
    (check-main-thread 'define-table)
    (unless (or (not doc) (string? doc))
      (assertion-violation 'define-table "not a documentation string" doc))
    (registry-define! tables name
      (lambda (symbol module) (new-table symbol module doc #f #f #f #f '() (make-mutex) #t))
      (lambda (t) (table-doc-set! t doc) t)))

  (define-syntax define-table
    (lambda (x)
      (syntax-case x ()
        [(_ id) (identifier? #'id) #'(define-table id #f)]
        [(_ id doc) (identifier? #'id) #'(define-exported id (make-table 'id doc))])))

  (define (existing-key-layers t key)
    (with-table-read t (find-key-layers t key)))

  (define (no-update ls before l) (void))

  (define (key-layers! t key)
    (or (find-key-layers t key)
        (let ([ls (make-value-layers 'table-entry (table-symbol t) layer-after? no-update #f)])
          (with-quit-safe-mutex (table-mutex t)
            (hashtable-set! (key-table t key #t) key ls))
          (table-order-set! t (cons key (table-order t)))
          ls)))

  (define table-set!
    (case-lambda
      [(t key) (table-set! t key #t)]
      [(t key v)
       (changing-table 'table-set! t)
       (let ([owner (check-current-owner 'table-set!)])
         (add-layer! (key-layers! t key) owner key v))]))

  (define (table-remove! t key)
    (changing-table 'table-remove! t)
    (let ([owner (check-current-owner 'table-remove!)] [ls (existing-key-layers t key)])
      (when ls
        (remove-layers! ls owner key #f))))

  (define (in-effect ls)
    (and ls (pair? (layers-in-effect ls)) (car (layers-in-effect ls))))

  (define table-ref
    (case-lambda
      [(t key) (table-ref t key #f)]
      [(t key default)
       (let ([l (in-effect (existing-key-layers (table-of 'table-ref t) key))])
         (if l (layer-value l) default))]))

  (define (table-owner t key)
    (let ([l (in-effect (existing-key-layers (table-of 'table-owner t) key))])
      (and l (owner-name (layer-owner l)))))

  (define (table-entries t)
    (table-of 'table-entries t)
    (with-table-read t
      (fold-left
        (lambda (entries key)
          (let ([l (in-effect (find-key-layers t key))])
            (if l (cons (cons key (layer-value l)) entries) entries)))
        '()
        (table-order t))))

  (define (table-documentation t)
    (table-doc (table-of 'documentation t))))
