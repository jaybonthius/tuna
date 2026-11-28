(import (tuna) (test) (tables) (rename (only (chezscheme) sleep) (sleep chez:sleep)))

(define (sleep-ms ms)
  (chez:sleep (make-time 'time-duration (* (mod ms 1000) 1000000) (quotient ms 1000))))

(define (raised-message thunk)
  (guard (c [#t (if (message-condition? c) (condition-message c) c)]) (thunk) #f))

(define (in-thread thunk)
  (let ([result #f])
    (join-task (fork-task (lambda (restore) (set! result (thunk)))))
    result))

;; The REPL's owner is made after the configuration's, so it ranks above
;; it, as in Tuna; tests start from fresh ones, since an owner's changes go
;; only when it unloads.
(define repl #f)
(define init #f)

(define (fresh-owners!)
  (when repl (unload-owner! repl))
  (when init (unload-owner! init))
  (set! init (make-owner '(tables init)))
  (set! repl (make-owner '(tables repl))))

(define (fresh-repl!)
  (unload-owner! repl)
  (set! repl (make-owner '(tables repl))))

(fresh-owners!)

(tables:define-table keymap "Keys and what they do.")
(tables:define-table symbols-only)

(define table-set!
  (case-lambda
    [(t k) (call-as-owner repl (lambda () (tables:set! t k)))]
    [(t k v) (call-as-owner repl (lambda () (tables:set! t k v)))]))
(define (init-set! t k v) (call-as-owner init (lambda () (tables:set! t k v))))
(define (table-remove! t k) (call-as-owner repl (lambda () (tables:remove! t k))))
(define (init-remove! t k) (call-as-owner init (lambda () (tables:remove! t k))))
(define table-ref (case-lambda [(t k) (tables:ref t k)] [(t k d) (tables:ref t k d)]))
(define (table-owner t k)
  (let ([o (tables:owner t k)])
    (cond [(eq? o repl) 'repl] [(eq? o init) 'init] [o (owner-name o)] [else #f])))

(define-record-type point (fields x))

(define-record-type pair-point (fields x))

(record-type-equal-procedure (record-type-descriptor pair-point)
  (lambda (a b equal?) (equal? (pair-point-x a) (pair-point-x b))))

(record-type-hash-procedure (record-type-descriptor pair-point)
  (lambda (p hash) (hash (pair-point-x p))))

(test "a table is a table, with its documentation"
  (check (tables:table? keymap))
  (check (not (tables:table? car)))
  (check-equal? "Keys and what they do." (tables:documentation keymap))
  (check-equal? #f (tables:documentation symbols-only)))

(test "tables:set! with no value sets #t, and tables:ref gives the default for a key with none"
  (table-set! keymap 'flag)
  (check-equal? #t (table-ref keymap 'flag))
  (check-equal? #f (table-ref keymap 'missing))
  (check-equal? 'none (table-ref keymap 'missing 'none))
  (fresh-repl!))

(test "the highest-ranked owner's entry is in effect, and a removal by a lower-ranked owner hides nothing"
  (init-set! keymap 'k 'init)
  (table-set! keymap 'k 'repl)
  (check-equal? 'repl (table-ref keymap 'k))
  (init-remove! keymap 'k)
  (check-equal? 'repl (table-ref keymap 'k))
  (fresh-owners!))

(test "evaluating tables:define-table again keeps the entries"
  (table-set! keymap 'kept 1)
  (eval '(tables:define-table keymap "Keys and what they do.") (interaction-environment))
  (check-equal? 1 (table-ref keymap 'kept))
  (fresh-repl!))

(test "a key of a kind the table has never held is not found, on any thread"
  (table-set! symbols-only 'a 1)
  (for-each
    (lambda (key)
      (check-equal? 'none (table-ref symbols-only key 'none))
      (check-equal? 'none (in-thread (lambda () (table-ref symbols-only key 'none)))))
    (list "a" #\a 1 '(a)))
  (check-equal? '((a . 1)) (tables:entries symbols-only))
  (fresh-repl!))

(test "keys of every kind are found by equal?"
  (let ([keys (list 'sym "str" #\c 42 #t #f '() (list 'C-c #\l 3) 1.5 (expt 10 30) (vector 1 "v") 1 1.0)])
    (for-each (lambda (k i) (table-set! keymap k i)) keys (iota (length keys)))
    (for-each
      (lambda (k i)
        (check-equal? i (table-ref keymap (if (string? k) (string-copy k) k)))
        (check-equal? 'repl (table-owner keymap k)))
      keys (iota (length keys)))
    (check-equal? 'none (table-ref keymap 'other 'none))
    (check-equal? 'none (table-ref keymap "other" 'none))
    (check-equal? 'none (table-ref keymap 2 'none))
    (check-equal? (map cons keys (iota (length keys))) (tables:entries keymap))
    (init-set! keymap (string-copy "str") 'init)
    (check-equal? 1 (table-ref keymap "str"))
    (fresh-repl!)
    (check-equal? 'init (table-ref keymap "str"))
    (check-equal? 'init (table-owner keymap (string-copy "str")))
    (call-as-owner init (lambda () (tables:remove! keymap (string-copy "str"))))
    (check-equal? '() (tables:entries keymap))
    (fresh-owners!)))

(test "procedures and records are keys by eq?, unless their type compares them otherwise"
  (let* ([f (lambda () 'f)] [g (lambda () 'g)] [a (make-point 1)] [b (make-point 1)]
         [c (make-pair-point 1)] [keys (list f a g keymap b c)])
    (for-each (lambda (k i) (table-set! keymap k i)) keys (iota (length keys)))
    (check-equal? (map cons keys (iota (length keys))) (tables:entries keymap))
    (check-equal? '(0 1 2 3 4 5) (map (lambda (k) (table-ref keymap k)) keys))
    (check-equal? 5 (table-ref keymap (make-pair-point 1)))
    (check-equal? 'none (table-ref keymap (lambda () 'f) 'none))
    (check-equal? 'none (table-ref keymap (make-point 1) 'none))
    (check-equal? '(0 4) (in-thread (lambda () (list (table-ref keymap f) (table-ref keymap b)))))
    (check-equal? 'repl (table-owner keymap g))
    (table-remove! keymap a)
    (table-remove! keymap (make-pair-point 1))
    (check-equal? (list (cons f 0) (cons g 2) (cons keymap 3) (cons b 4)) (tables:entries keymap))
    (fresh-repl!)
    (check-equal? '() (tables:entries keymap))))

(test "other threads read a table while the main thread adds keys"
  (table-set! keymap 'first 1)
  (let ([stop? #f] [bad 0] [reads 0] [mutex (make-mutex)])
    (define (reader)
      (fork-task
        (lambda (restore)
          (let loop ([n 0] [wrong 0] [last 0])
            (if stop?
                (with-mutex mutex (set! bad (+ bad wrong)) (set! reads (+ reads n)))
                (let ([count (length (tables:entries keymap))])
                  (loop (+ n 1)
                        (if (and (eqv? 1 (table-ref keymap 'first)) (>= count last)) wrong (+ wrong 1))
                        count)))))))
    (let ([readers (list (reader) (reader) (reader))])
      (do ([i 0 (+ i 1)]) ((= i 5000))
        (table-set! keymap i (- i)))
      (set! stop? #t)
      (for-each join-task readers))
    (check-equal? 0 bad)
    (check (> reads 0))
    (check-equal? -4999 (in-thread (lambda () (table-ref keymap 4999))))
    (fresh-repl!)
    (check-equal? '() (tables:entries keymap))))

(test "other threads read a table while the main thread re-sets and removes keys"
  (do ([k 0 (+ k 1)]) ((= k 10)) (table-set! keymap k 0))
  (let ([stop? #f] [raised 0] [unbound 0] [reads 0] [mutex (make-mutex)])
    (define (reader)
      (fork-task
        (lambda (restore)
          (let loop ([n 0] [r 0] [u 0])
            (if stop?
                (with-mutex mutex
                  (set! raised (+ raised r))
                  (set! unbound (+ unbound u))
                  (set! reads (+ reads n)))
                (case (guard (c [#t 'raised])
                        (let ([k (random 10)])
                          (do ([j 0 (fx+ j 1)]) ((fx= j 20))
                            (table-ref keymap 'removed)
                            (tables:owner keymap 'removed))
                          (and (table-ref keymap k) (tables:owner keymap k)
                               (<= 10 (length (tables:entries keymap)) 11))))
                  [(raised) (loop (+ n 1) (+ r 1) u)]
                  [(#f) (loop (+ n 1) r (+ u 1))]
                  [else (loop (+ n 1) r u)]))))))
    (let ([readers (list (reader) (reader) (reader) (reader))])
      (do ([i 1 (+ i 1)]) ((= i 20000))
        (table-set! keymap (fxmod i 10) i)
        (if (fxeven? i) (table-set! keymap 'removed i) (table-remove! keymap 'removed)))
      (set! stop? #t)
      (for-each join-task readers))
    (check-equal? 0 raised)
    (check-equal? 0 unbound)
    (check (> reads 0))
    (fresh-repl!)
    (check-equal? '() (tables:entries keymap))))

(test "only the main thread changes tables"
  (for-each
    (lambda (thunk) (check-equal? "only the main thread makes changes" (in-thread (lambda () (raised-message thunk)))))
    (list (lambda () (table-set! keymap 'k 1))
          (lambda () (table-remove! keymap 'k))))
  (check-equal? '() (tables:entries keymap)))

(test "a cancel never leaves a table entry half made"
  (let ([cancelled 0])
    (do ([i 0 (+ i 1)]) ((= i 300))
      (let ([t (spawn-task
                 (lambda (restore)
                   (let loop ()
                     (do ([j 0 (fx+ j 1)]) ((fx= j 10))
                       (table-set! keymap j j)
                       (init-set! keymap j (- j))
                       (table-remove! keymap j))
                     (loop))))])
        (fork-task (lambda (restore) (sleep-ms (random 3)) (cancel-task t)))
        (let-values ([(how detail) (join-task t)])
          (when (eq? how 'cancelled) (set! cancelled (+ cancelled 1))))))
    (check (> cancelled 250))
    (fresh-owners!)
    (check-equal? '() (tables:entries keymap))))

(test "a removal hides the entries of owners ranked below it until its owner unloads"
  (load-module! '(tables-test binder))
  (let ([binder (module-owner '(tables-test binder))])
    (check-equal? 'binder (table-ref keymap 'k))
    (init-remove! keymap 'k)
    (check-equal? 'none (table-ref keymap 'k 'none))
    (reload-modules! '((tables-test binder)))
    (check-equal? 'none (table-ref keymap 'k 'none))
    (unload-owner! init)
    (set! init (make-owner '(tables init)))
    (check-equal? 'binder (table-ref keymap 'k))
    (table-remove! keymap 'k)
    (check-equal? 'none (table-ref keymap 'k 'none))
    (unload-owner! (module-owner '(tables-test binder)))
    (fresh-owners!)
    (check-equal? '() (tables:entries keymap))))
