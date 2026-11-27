#!tuna
;; Each owner has at most one entry or removal per key. A key's entries are
;; kept by owner rank, so the one in effect is found without sorting.
(define-record-type (%item %make-item %item?)
  (nongenerative)
  (sealed #t)
  (fields owner value removal? sequence))

(define-record-type (%entry %make-entry entry?)
  (nongenerative)
  (sealed #t)
  (fields owner key value))

(define (entry-owner e) (%entry-owner e))
(define (entry-key e) (%entry-key e))
(define (entry-value e) (%entry-value e))

;; Keys whose equal? is eq?, eqv? or string=? get hashtables of their own,
;; since equal-hash gives every procedure and record one hash. A key held
;; only by removals is held weakly: once nothing else refers to it no owner
;; can add an entry for it, so the removals go with it.
(define-record-type (%set %make-set set?)
  (nongenerative)
  (sealed #t)
  (fields name (mutable on-drop) symbols eqvs strings eqs weak-eqs equals (mutable sequence))
  (protocol
    (lambda (new)
      (lambda (name on-drop)
        (new name on-drop (make-hashtable symbol-hash eq?) (make-eqv-hashtable)
             (make-hashtable string-hash string=?) (make-eq-hashtable) (make-weak-eq-hashtable)
             (make-hashtable equal-hash equal?) 0)))))

;; In a module, so Chez may inline these calls, as it never does a call of
;; a changeable procedure: every change and read makes several.
(module %internals (%items %store! %item<? %check-set %changing-owner %put! %in-effect)
  (define (%eq-key? key)
    (or (procedure? key)
        (and (record? key) (not (record-equal-procedure key key)) (not (default-record-equal-procedure)))))

  (define (%table s key)
    (cond
      [(symbol? key) (%set-symbols s)]
      [(or (fixnum? key) (char? key) (boolean? key)) (%set-eqvs s)]
      [(string? key) (%set-strings s)]
      [(%eq-key? key) (%set-eqs s)]
      [else (%set-equals s)]))

  (define (%items s key)
    (let ([t (%table s key)])
      (or (hashtable-ref t key #f)
          (and (eq? t (%set-eqs s)) (hashtable-ref (%set-weak-eqs s) key #f))
          '())))

  (define (%store! s key items)
    (let ([t (%table s key)])
      (cond
        [(not (eq? t (%set-eqs s)))
         (if (null? items) (hashtable-delete! t key) (hashtable-set! t key items))]
        [else
         (hashtable-delete! t key)
         (hashtable-delete! (%set-weak-eqs s) key)
         (cond
           [(null? items)]
           [(for-all %item-removal? items) (hashtable-set! (%set-weak-eqs s) key items)]
           [else (hashtable-set! t key items)])])))

  (define (%item<? a b)
    (or (owner<? (%item-owner a) (%item-owner b))
        (and (eq? (%item-owner a) (%item-owner b)) (fx< (%item-sequence a) (%item-sequence b)))))

  (define (%check-set who s)
    (unless (set? s) (assertion-violation who "not a set of owned entries" s)))

  (define %main-thread (get-thread-id))

  (define (%changing-owner who)
    (unless (eqv? (get-thread-id) %main-thread)
      (assertion-violation who "only the main thread makes changes"))
    (let ([o (current-owner)])
      (unless (and o (owner-live? o) (not (equal? (owner-name o) '(tuna))))
        (assertion-violation who "this code acts for no live owner" o))
      o))

  ;; A change is made masked, so a cancel never leaves a set half changed.
  (define (%put! who s key value removal?)
    (%check-set who s)
    (let ([o (%changing-owner who)])
      (call-with-cancellation-masked
        (lambda (restore)
          (let ([n (fx+ (%set-sequence s) 1)])
            (%set-sequence-set! s n)
            (%store! s key
              (list-sort %item<?
                (cons (%make-item o value removal? n)
                      (remp (lambda (i) (eq? (%item-owner i) o)) (%items s key))))))))))

  ;; A removal hides the entries of owners ranked below it. Owners whose
  ;; unload has begun count for nothing, whether or not their entries are
  ;; dropped yet.
  (define (%in-effect items)
    (let loop ([items (reverse items)] [kept '()])
      (cond
        [(null? items) kept]
        [(not (owner-live? (%item-owner (car items)))) (loop (cdr items) kept)]
        [(%item-removal? (car items)) kept]
        [else (loop (cdr items) (cons (car items) kept))]))))

(import %internals)

(define %sets (make-eq-hashtable))

(define (make name on-drop)
  (unless (symbol? name) (assertion-violation 'owned:make "not a symbol" name))
  (unless (procedure? on-drop) (assertion-violation 'owned:make "not a procedure" on-drop))
  (let ([s (hashtable-ref %sets name #f)])
    (if s
        (begin (%set-on-drop-set! s on-drop) s)
        (let ([s (%make-set name on-drop)])
          (hashtable-set! %sets name s)
          s))))

(define (add! s key value) (%put! 'owned:add! s key value #f))

(define (remove! s key) (%put! 'owned:remove! s key #f #t))

(define (withdraw! s key)
  (%check-set 'owned:withdraw! s)
  (let ([o (%changing-owner 'owned:withdraw!)])
    (call-with-cancellation-masked
      (lambda (restore)
        (%store! s key (remp (lambda (i) (eq? (%item-owner i) o)) (%items s key)))))))

(define (key-entries s key)
  (%check-set 'owned:key-entries s)
  (map (lambda (i) (%make-entry (%item-owner i) key (%item-value i))) (%in-effect (%items s key))))

(define (holds? s key)
  (%check-set 'owned:holds? s)
  (pair? (%items s key)))

(define (entries s)
  (%check-set 'owned:entries s)
  (let ([all '()])
    (for-each
      (lambda (t)
        (let-values ([(keys values) (hashtable-entries t)])
          (vector-for-each
            (lambda (key items)
              (for-each (lambda (i) (set! all (cons (cons i key) all))) (%in-effect items)))
            keys values)))
      (list (%set-symbols s) (%set-eqvs s) (%set-strings s) (%set-eqs s) (%set-equals s)))
    (map (lambda (p) (%make-entry (%item-owner (car p)) (cdr p) (%item-value (car p))))
         (list-sort (lambda (a b) (%item<? (car a) (car b))) all))))

;; After the owner's own clean-up, so its entries count until it is done
;; with them; the set's maker learns what changed through on-drop.
(define (%drop-owner! owner)
  (let-values ([(names sets) (hashtable-entries %sets)])
    (vector-for-each
      (lambda (s)
        (let ([changed? #f])
          (for-each
            (lambda (t)
              (let-values ([(keys values) (hashtable-entries t)])
                (vector-for-each
                  (lambda (key items)
                    (when (exists (lambda (i) (eq? (%item-owner i) owner)) items)
                      (set! changed? #t)
                      (%store! s key (remp (lambda (i) (eq? (%item-owner i) owner)) items))))
                  keys values)))
            (list (%set-symbols s) (%set-eqvs s) (%set-strings s) (%set-eqs s) (%set-weak-eqs s)
                  (%set-equals s)))
          (when changed?
            (%call-reporting (%set-on-drop s)))))
      sets)))

;; One set's on-drop that raises must not keep the others from learning
;; of the drop.
(define (%call-reporting thunk)
  (guard (c [(cancelled? c) (raise c)] [#t (report c)])
    (thunk)))

(advice-add! owner-unloading
  (lambda (next owner)
    (next owner)
    (%drop-owner! owner)))
