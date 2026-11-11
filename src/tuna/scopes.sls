(library (tuna scopes)
  (export
    current-scope
    make-scope
    scope?
    the-current-scope
    make-local-key
    scope-local
    scopes-with-locals
    scope-layers!
    forget-local-layers!)
  (import (chezscheme) (tuna core changes))

  ;; A scope's local values are kept apart from the scope, so that the
  ;; guardian can hand them back once the scope is collected and the
  ;; changes made in it can be forgotten. The changes refer to the local
  ;; values, never to the scope, so they do not keep it alive.
  (define-record-type locals
    (nongenerative)
    (sealed #t)
    (fields (mutable values)))

  (define-record-type (scope new-scope scope?)
    (nongenerative)
    (sealed #t)
    (fields locals))

  (define (make-scope) (new-scope (make-locals '#())))

  (define current-scope
    (make-thread-parameter #f
      (lambda (s)
        (unless (or (not s) (scope? s))
          (assertion-violation 'current-scope "not a scope or #f" s))
        s)))

  (define (the-current-scope who)
    (or (current-scope) (assertion-violation who "the current scope is #f")))

  ;; A scope's values are a vector indexed by key, so a read costs the same
  ;; however many options and hooks the scope sets. Other threads read it
  ;; while the main thread changes it: vector-set! is safe for that, and a
  ;; longer vector is filled before it replaces the shorter one.
  (define next-key 0)

  (define (make-local-key)
    (let ([key next-key])
      (set! next-key (fx+ key 1))
      key))

  (define (scope-local s key)
    (let ([v (locals-values (scope-locals s))])
      (and (fx< key (vector-length v)) (vector-ref v key))))

  (define scopes (make-weak-eq-hashtable))
  (define collected (make-guardian))

  (define (forget-collected-scopes!)
    (let ([locals (collected)])
      (when locals
        (vector-for-each (lambda (ls) (when ls (forget-layers! ls))) (locals-values locals))
        (forget-collected-scopes!))))

  (define (scope-local-set! s key v)
    (let* ([locals (scope-locals s)] [old (locals-values locals)] [n (vector-length old)])
      (cond
        [(fx< key n) (vector-set! old key v)]
        [v (let ([longer (make-vector (fxmax (fx+ key 1) (fx* n 2)) #f)])
             (do ([i 0 (fx+ i 1)]) ((fx= i n)) (vector-set! longer i (vector-ref old i)))
             (vector-set! longer key v)
             (locals-values-set! locals longer))])))

  (define (scopes-with-locals)
    (vector->list (hashtable-keys scopes)))

  (define (scope-layers! s key make)
    (forget-collected-scopes!)
    (or (scope-local s key)
        (let ([ls (make)])
          (unless (hashtable-contains? scopes s)
            (hashtable-set! scopes s #t)
            (collected s (scope-locals s)))
          (scope-local-set! s key ls)
          ls)))

  (define (forget-local-layers! key)
    (for-each
      (lambda (s)
        (let ([ls (scope-local s key)])
          (when ls
            (forget-layers! ls)
            (scope-local-set! s key #f))))
      (scopes-with-locals))))
