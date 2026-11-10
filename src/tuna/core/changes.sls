(library (tuna core changes)
  (export
    module-name?
    prefixed-symbol
    current-owner
    this-module
    as-module
    owner-rank
    rank-module!
    unrank-module!
    move-before-importers!

    change-owner
    change-kind
    change-thing
    change-detail
    change-sequence
    record-change!
    take-back!
    owner-changes
    module-changes

    check-main-thread)
  (import (chezscheme))

  (define (module-name? x)
    (and (pair? x) (list? x) (for-all symbol? x)))

  (define (prefixed-symbol module name)
    (string->symbol
      (call-with-string-output-port
        (lambda (p)
          (let loop ([parts module])
            (display (car parts) p)
            (unless (null? (cdr parts))
              (put-char p #\/)
              (loop (cdr parts))))
          (put-char p #\:)
          (display name p)))))

  (define current-owner (make-thread-parameter '(repl)))

  (define-syntax this-module
    (syntax-rules ()
      [(_) (current-owner)]))

  (define main-thread-id (get-thread-id))

  (define (on-main-thread?) (fx= (get-thread-id) main-thread-id))

  (define (check-main-thread who)
    (unless (on-main-thread?)
      (assertion-violation who "only the main thread makes changes")))

  ;; A band is wider than the number of ranks one process takes.
  (define outside-band 0)
  (define lib-band (expt 2 40))
  (define init-rank (expt 2 41))
  (define repl-rank (+ init-rank 1))

  (define ranks (make-hashtable equal-hash equal?))
  (define next-rank 1)

  ;; as-module reads ranks on any thread. The main thread, their only
  ;; writer, reads them without the lock.
  (define ranks-mutex (make-mutex))

  (define (take-rank! band)
    (let ([rank (+ band next-rank)])
      (set! next-rank (+ next-rank 1))
      rank))

  (define (owner-rank owner)
    (cond
      [(equal? owner '(repl)) repl-rank]
      [(equal? owner '(init)) init-rank]
      [(equal? owner '(tuna)) 0]
      [else (hashtable-ref ranks owner #f)]))

  (define (rank-module! name lib?)
    (unless (hashtable-contains? ranks name)
      (let ([rank (take-rank! (if lib? lib-band outside-band))])
        (with-mutex ranks-mutex (hashtable-set! ranks name rank)))))

  (define (unrank-module! name)
    (with-mutex ranks-mutex (hashtable-delete! ranks name)))

  ;; An importer takes its rank only after its imports have run, so a fresh
  ;; rank puts the import before it.
  (define (move-before-importers! name)
    (let ([rank (hashtable-ref ranks name #f)])
      (when (and rank (>= rank lib-band))
        (let ([rank (take-rank! outside-band)])
          (with-mutex ranks-mutex (hashtable-set! ranks name rank)))
        (for-each (lambda (c) ((change-reorder c))) (owner-changes name)))))

  (define (call-as-module name thunk)
    (unless (module-name? name)
      (assertion-violation 'as-module "not a module name" name))
    (unless (and (with-mutex ranks-mutex (owner-rank name)) (not (equal? name '(tuna))))
      (assertion-violation 'as-module "not a loaded module" name))
    (parameterize ([current-owner name]) (thunk)))

  (define-syntax as-module
    (syntax-rules ()
      [(_ module-expr body1 body2 ...)
       (call-as-module module-expr (lambda () body1 body2 ...))]))

  (define-record-type change
    (nongenerative)
    (sealed #t)
    (fields owner kind thing detail sequence undo reorder))

  (define changes (make-hashtable equal-hash equal?))
  (define next-sequence 0)

  (define (owner-changes owner)
    (hashtable-ref changes owner '()))

  (define (record-change! who kind thing detail undo reorder)
    (check-main-thread who)
    (let ([owner (current-owner)])
      (set! next-sequence (+ next-sequence 1))
      (let ([c (make-change owner kind thing detail next-sequence undo reorder)])
        (hashtable-update! changes owner (lambda (cs) (cons c cs)) '())
        c)))

  (define (forget-change! c)
    (hashtable-update! changes (change-owner c) (lambda (cs) (remq c cs)) '()))

  (define (take-back! c)
    (forget-change! c)
    ((change-undo c)))

  (define (module-changes name)
    (unless (module-name? name)
      (assertion-violation 'module-changes "not a module name" name))
    (map (lambda (c) (list (change-kind c) (change-thing c) (change-detail c)))
         (owner-changes name))))
