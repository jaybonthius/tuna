(library (tuna scopes)
  (export
    current-scope
    make-scope
    scope?
    the-current-scope
    make-local-key
    scope-local
    scope-local-set!
    scopes-with-locals
    record-scope-change!
    forget-scope-change!)
  (import (chezscheme) (tuna core changes))

  ;; A scope's local values are kept apart from the scope, so that the
  ;; guardian can hand them back once the scope is collected and the
  ;; changes made in it can be forgotten. The changes refer to the locals,
  ;; never to the scope, so they do not keep it alive.
  (define-record-type locals
    (nongenerative)
    (sealed #t)
    (fields (mutable values) (mutable changes)))

  (define-record-type (scope new-scope scope?)
    (nongenerative)
    (sealed #t)
    (fields locals))

  (define (make-scope) (new-scope (make-locals '#() '())))

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
        (for-each forget-change! (locals-changes locals))
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

  (define (record-scope-change! s who kind thing detail undo reorder)
    (check-main-thread who)
    (forget-collected-scopes!)
    (let ([locals (scope-locals s)])
      (unless (hashtable-contains? scopes s)
        (hashtable-set! scopes s #t)
        (collected s locals))
      (letrec ([c (record-change! who kind thing detail
                    (lambda ()
                      (locals-changes-set! locals (remq c (locals-changes locals)))
                      (undo))
                    reorder)])
        (locals-changes-set! locals (cons c (locals-changes locals)))
        c)))

  (define (forget-scope-change! s c)
    (let ([locals (scope-locals s)])
      (locals-changes-set! locals (remq c (locals-changes locals)))
      (forget-change! c))))
