#!tuna
(import (owned))

;; A table's entries live in owned's set of its full name, so they outlive
;; a reload of the defining module or of tables. Each key's entry in effect
;; is kept here, worked out at each change, so a read is one lookup; a key
;; whose entry's owner has begun to unload is worked out again when read.
;; Only the main thread changes a table and reads without the mutex; other
;; threads take it, since a hashtable read while another thread adds to it
;; can see it half changed. A key's entry is kept in a box, so a change to
;; a key the hashtable holds is one write, which needs no mutex.
(define-record-type (%table %make-table table?)
  (nongenerative)
  (sealed #t)
  (fields symbol (mutable doc) (mutable set)
          (mutable symbol-keys) (mutable eqv-keys) (mutable string-keys) (mutable eq-keys)
          (mutable equal-keys) (mutable order) mutex))

(define %tables (make-eq-hashtable))
(define %main-thread (get-thread-id))

(define (%key-tables t)
  (filter values (list (%table-symbol-keys t) (%table-eqv-keys t) (%table-string-keys t) (%table-eq-keys t)
                       (%table-equal-keys t))))

(define (%full-symbol module name)
  (if (member module '((init) (repl)))
      name
      (string->symbol (format "~{~a~^/~}:~a" module name))))

;; In a module, so Chez may inline these calls, as it never does a call of
;; a changeable procedure: every lookup makes several.
(module %internals (%on-main-thread? %of %refresh-key! %refresh-all! %cell-entry %entry)
  (define (%on-main-thread?) (eqv? (get-thread-id) %main-thread))

  ;; An equal-hash lookup costs several times a symbol, eqv or string one,
  ;; and equal-hash gives every procedure and every record one hash, so keys
  ;; whose equal? is eq?, eqv? or string=? have hashtables of their own, each
  ;; made when the first key of its kind is stored.
  (define-syntax %key-table
    (syntax-rules ()
      [(_ t key make?)
       (let-syntax ([kind (syntax-rules ()
                            [(_ keys keys-set! make-keys)
                             (or (keys t) (and make? (let ([new make-keys]) (keys-set! t new) new)))])])
         (cond
           [(symbol? key) (kind %table-symbol-keys %table-symbol-keys-set! (make-hashtable symbol-hash eq?))]
           [(or (fixnum? key) (char? key) (boolean? key))
            (kind %table-eqv-keys %table-eqv-keys-set! (make-eqv-hashtable))]
           [(string? key) (kind %table-string-keys %table-string-keys-set! (make-hashtable string-hash string=?))]
           [(%eq-key? key) (kind %table-eq-keys %table-eq-keys-set! (make-eq-hashtable))]
           [else (kind %table-equal-keys %table-equal-keys-set! (make-hashtable equal-hash equal?))]))]))

  (define (%eq-key? key)
    (or (procedure? key)
        (and (record? key) (not (record-equal-procedure key key)) (not (default-record-equal-procedure)))))

  (define (%of who t)
    (unless (table? t) (assertion-violation who "not a table" t))
    t)

  ;; A key's box, which holds its entry in effect, a pair of its owner and
  ;; value, or #f.
  (define (%cell t key)
    (let ([keys (%key-table t key #f)])
      (and keys (hashtable-ref keys key #f))))

  ;; A key whose entries a removal hides, or whose owners' unload took them,
  ;; stays in its hashtable, holding #f, so it keeps its place in the order
  ;; keys first took an entry, as a plugin's do across its reload; a key its
  ;; owners took back themselves goes, so keys made for a moment, such as a
  ;; highlight's span source, do not pile up. The order is a list of each
  ;; key and its box, so a walk over the entries looks up no key.
  (define (%refresh-key! t key)
    (%refresh-key-keeping! t key #f))

  (define (%refresh-key-keeping! t key keep?)
    (let ([es (owned:key-entries (%table-set t) key)] [cell (%cell t key)])
      (cond
        [(pair? es)
         (let* ([e (car (last-pair es))] [entry (cons (owned:entry-owner e) (owned:entry-value e))])
           (if cell
               (set-box! cell entry)
               (let ([cell (box entry)])
                 (with-mutex (%table-mutex t)
                   (hashtable-set! (%key-table t key #t) key cell)
                   (%table-order-set! t (cons (cons key cell) (%table-order t)))))))]
        [(not cell)]
        [(or keep? (owned:holds? (%table-set t) key)) (set-box! cell #f)]
        [else
         (set-box! cell #f)
         (with-mutex (%table-mutex t)
           (hashtable-delete! (%key-table t key #f) key)
           (%table-order-set! t (remp (lambda (key+cell) (eq? (cdr key+cell) cell)) (%table-order t))))])))

  (define (%refresh-all! t)
    (let ([order (with-mutex (%table-mutex t) (%table-order t))])
      (for-each (lambda (key+cell) (%refresh-key-keeping! t (car key+cell) #t)) order))
    (for-each (lambda (e) (%refresh-key! t (owned:entry-key e))) (owned:entries (%table-set t))))

  (define (%cell-entry t key cell)
    (let ([e (unbox cell)])
      (if (and e (not (owner-live? (car e))) (%on-main-thread?))
          (begin (%refresh-key! t key) (unbox cell))
          e)))

  (define (%entry t key)
    (let ([cell (if (%on-main-thread?) (%cell t key) (with-mutex (%table-mutex t) (%cell t key)))])
      (and cell (%cell-entry t key cell)))))

(import %internals)

(define (%define-table module name doc)
  (unless (or (not doc) (string? doc)) (assertion-violation 'tables:define-table "not a documentation string" doc))
  (let* ([symbol (%full-symbol module name)]
         [t (or (hashtable-ref %tables symbol #f)
                (let ([t (%make-table symbol doc #f #f #f #f #f #f '() (make-mutex))])
                  (hashtable-set! %tables symbol t)
                  t))])
    (%table-doc-set! t doc)
    (%table-set-set! t (owned:make symbol (lambda () (%refresh-all! t))))
    (%refresh-all! t)
    t))

(define-syntax define-table
  (syntax-rules ()
    [(_ id) (define-table id #f)]
    [(_ id doc) (define-public id (%define-table (owner-name (current-owner)) 'id doc))]))

(define set!
  (case-lambda
    [(t key) (set! t key #t)]
    [(t key v)
     (%of 'tables:set! t)
     (call-with-cancellation-masked
       (lambda (restore)
         (owned:add! (%table-set t) key v)
         (%refresh-key! t key)))]))

(define (remove! t key)
  (%of 'tables:remove! t)
  (call-with-cancellation-masked
    (lambda (restore)
      (owned:remove! (%table-set t) key)
      (%refresh-key! t key))))

(define ref
  (case-lambda
    [(t key) (ref t key #f)]
    [(t key default)
     (let ([e (%entry (%of 'tables:ref t) key)])
       (if e (cdr e) default))]))

(define (owner t key)
  (let ([e (%entry (%of 'tables:owner t) key)])
    (and e (car e))))

;; In the order keys first took an entry, the oldest first.
(define (entries t)
  (%of 'tables:entries t)
  (fold-left
    (lambda (entries key+cell)
      (let ([e (%cell-entry t (car key+cell) (cdr key+cell))])
        (if e (cons (cons (car key+cell) (cdr e)) entries) entries)))
    '()
    (if (%on-main-thread?) (%table-order t) (with-mutex (%table-mutex t) (%table-order t)))))

(define (documentation t) (%table-doc (%of 'tables:documentation t)))
