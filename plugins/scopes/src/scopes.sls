#!tuna
;; A scope's values are a vector indexed by key, so a read costs the same
;; however many options and hooks the scope sets. Other threads read it
;; while the main thread changes it: vector-set! is safe for that, and a
;; longer vector is filled before it replaces the shorter one.
(define-record-type (%scope-record %new-scope scope?)
  (nongenerative)
  (sealed #t)
  (fields (mutable values)))

(define (make) (%new-scope '#()))

(define current
  (make-thread-parameter #f
    (lambda (s)
      (unless (or (not s) (scope? s))
        (assertion-violation 'scopes:current "not a scope or #f" s))
      s)))

;; Keyed by name, so the plugin that made a key finds the scopes' values
;; again after it reloads.
(define %keys (make-eq-hashtable))

(define (make-key name)
  (unless (symbol? name) (assertion-violation 'scopes:make-key "not a symbol" name))
  (or (hashtable-ref %keys name #f)
      (let ([key (hashtable-size %keys)])
        (hashtable-set! %keys name key)
        key)))

(define (%check-scope who s)
  (unless (scope? s) (assertion-violation who "not a scope" s)))

(define (ref s key)
  (%check-scope 'scopes:ref s)
  (let ([v (%scope-record-values s)])
    (and (fx< key (vector-length v)) (vector-ref v key))))

;; Weakly, so a scope plugins no longer hold is collected with its values.
(define %holding (make-weak-eq-hashtable))

(define (set! s key v)
  (%check-scope 'scopes:set! s)
  (let* ([old (%scope-record-values s)] [n (vector-length old)])
    (cond
      [(fx< key n) (vector-set! old key v)]
      [v (let ([longer (make-vector (fxmax (fx+ key 1) (fx* n 2)) #f)])
           (do ([i 0 (fx+ i 1)]) ((fx= i n)) (vector-set! longer i (vector-ref old i)))
           (vector-set! longer key v)
           (%scope-record-values-set! s longer))])
    (when v (hashtable-set! %holding s #t))))

(define (holding key)
  (filter (lambda (s) (ref s key)) (vector->list (hashtable-keys %holding))))
