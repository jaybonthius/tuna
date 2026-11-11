(import (chezscheme) (tuna test) (chez-lang loader) (tuna core modules)
        (only (tuna core changes) rank-module! move-before-importers!))

(define root
  (let ([dir (format "/tmp/tuna-definitions-test-~a" (get-process-id))])
    (mkdir dir)
    dir))

(define (write-module! name text)
  (call-with-output-file (string-append root "/lib/" name ".sls")
    (lambda (p) (put-string p text))))

(mkdir (string-append root "/lib"))
(write-module! "racer"
  "#!tuna
(define (f x) (+ x 1))
(define (assign-f! g) (set! f g))
(define (h x) x)
(define (assign-h! g) (set! h g))
")

(compile-file-message #f)
(install-module-lookup! (library-directories) (string-append root "/lib") (string-append root "/library")
  (string-append root "/cache") (lambda (name) #f) (lambda (name) #f) (lambda (name) #f) (lambda () '()))
(install-loader!)

(rank-module! '(early-lib) #t)
(define env (environment '(chezscheme) '(tuna) '(racer)))
(define (compiled form) (eval form env))

(define call-f (compiled '(lambda (x) (racer:f x))))
(define assign-f! (compiled 'racer:assign-f!))
(define override-f! (compiled '(lambda (g) (set! racer:f g))))
(define advise-f! (compiled '(lambda (p) (advice-add! racer:f p))))
(define unadvise-f! (compiled '(lambda (p) (advice-remove! racer:f p))))
(define f-changes (compiled '(lambda () (definition-changes racer:f))))
(define f-value (compiled '(lambda () racer:f)))
(define call-h (compiled '(lambda (x) (racer:h x))))
(define assign-h! (compiled 'racer:assign-h!))
(define advise-h! (compiled '(lambda (p) (advice-add! racer:h p))))
(define unadvise-h! (compiled '(lambda (p) (advice-remove! racer:h p))))

(define (double f x) (* 2 (f x)))
(define (plus-100 x) (+ x 100))

(define (on-thread thunk)
  (let ([result #f])
    (thread-join (fork-thread (lambda () (set! result (thunk)))))
    result))

(define (raised-message thunk)
  (guard (c [#t (condition-message c)]) (thunk) #f))

(test "changes on another thread raise and change nothing"
  (check-equal? "only the main thread makes changes"
    (on-thread (lambda () (raised-message (lambda () (override-f! plus-100))))))
  (check-equal? "only the main thread makes changes"
    (on-thread (lambda () (raised-message (lambda () (advise-f! double))))))
  (advise-f! double)
  (check-equal? "only the main thread makes changes"
    (on-thread (lambda () (raised-message (lambda () (unadvise-f! double))))))
  (unadvise-f! double)
  (check-equal? '(((racer) define #f)) (f-changes))
  (check-equal? 2 (call-f 1)))

(test "a module assigns its own definition from any thread"
  (on-thread (lambda () (assign-f! (lambda (x) (- x)))))
  (check-equal? -1 (call-f 1))
  (check-equal? '(((racer) define #f)) (f-changes))
  (assign-f! (lambda (x) (+ x 1))))

(test "the procedure a name gives is the same on every thread"
  (check (eq? (f-value) (on-thread f-value))))

;; A caller must see one consistent definition in effect, never one
;; procedure's advice around another's stale value, while the main thread
;; changes it.
(test "calls on another thread during changes see whole states"
  (let* ([done #f]
         [bad '()]
         [caller (fork-thread
                   (lambda ()
                     (let loop ([n 0])
                       (unless done
                         (let ([v (guard (c [#t c]) (call-f 1))])
                           (unless (memv v '(2 4 101 202))
                             (set! bad (cons v bad))))
                         (loop (+ n 1))))))])
    (do ([i 0 (+ i 1)]) ((= i 20000))
      (advise-f! double)
      (override-f! plus-100)
      (unadvise-f! double)
      (override-f! (lambda (x) (+ x 1))))
    (set! done #t)
    (thread-join caller)
    (check-equal? '() bad)))

;; Each thread's last assignment can straddle the main thread's last
;; change, which must not leave the definition without its advice.
(test "assignments on many threads during changes leave a consistent state"
  (do ([trial 0 (+ trial 1)]) ((= trial 500))
    (let* ([stop #f]
           [threads
            (map (lambda (i)
                   (fork-thread
                     (lambda ()
                       (let loop ()
                         (assign-h! (lambda (x) i))
                         (unless stop (loop))))))
                 '(1 2 3 4))])
      (do ([k 0 (+ k 1)]) ((= k 20))
        (advise-h! double)
        (unadvise-h! double))
      (advise-h! double)
      (set! stop #t)
      (for-each thread-join threads)
      (check (memv (call-h 0) '(2 4 6 8)))
      (unadvise-h! double))))

;; Loading a module ranks it on the main thread while other threads assign
;; their module's definitions and run code on its behalf.
(test "assignments on other threads while modules load"
  (let* ([as-racer (compiled '(lambda (thunk) (as-module '(racer) (thunk))))]
         [stop #f]
         [bad '()]
         [threads
          (map (lambda (i)
                 (fork-thread
                   (lambda ()
                     (let loop ()
                       (as-racer (lambda () (assign-h! (lambda (x) i))))
                       (unless (memv (call-h 0) '(1 2 3 4))
                         (set! bad (cons (call-h 0) bad)))
                       (unless stop (loop))))))
               '(1 2 3 4))])
    (do ([i 0 (+ i 1)]) ((= i 40))
      (let ([name (format "loaded~a" i)])
        (write-module! name "#!tuna\n(define (f) 1)\n")
        (invoke-library (list (string->symbol name)))))
    (set! stop #t)
    (for-each thread-join threads)
    (check-equal? '() bad)
    (check-equal? '(((loaded39) define #f))
      (eval '(definition-changes loaded39:f) (environment '(chezscheme) '(tuna) '(loaded39))))))

;; A module imported from outside lib/ goes before its importer, which can
;; put an override that was beneath its definition after it.
(test "an override comes into effect when its definition's module moves before it"
  (let ([override-as (compiled '(lambda (owner g) (as-module owner (set! racer:f g))))])
    (take-back-changes! '(repl) '())
    (override-as '(early-lib) plus-100)
    (check-equal? 2 (call-f 1))
    (move-before-importers! '(racer))
    (check-equal? 101 (call-f 1))
    (take-back-changes! '(early-lib) '())
    (check-equal? 2 (call-f 1))))

(system (format "rm -rf '~a'" root))
(test-exit)
