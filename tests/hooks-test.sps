(import (chezscheme) (tuna test) (tuna core changes) (tuna core definitions) (tuna core modules)
        (except (tuna core main-thread) exit) (tuna hooks) (tuna scopes))

(define (raised-message thunk)
  (guard (c [#t (if (message-condition? c) (condition-message c) c)]) (thunk) #f))

(define (in-thread thunk)
  (let ([result #f])
    (thread-join (fork-thread (lambda () (set! result (thunk)))))
    result))

(define-hook changed)

(define (marker n) (lambda (calls) (set-box! calls (cons n (unbox calls)))))

(define markers (map marker (iota 6)))

(define (tests)
  ;; Moving a lib module out of the lib band sorts a hook's entries afresh,
  ;; so the order kept as entries come and go must match it.
  (test "entries kept in order as they are added, removed and taken back match a fresh sort"
    (let ([procedures (map marker (iota 5))] [mismatches 0])
      (do ([round 0 (+ round 1)]) ((= round 200))
        (let ([lib (list 'hook-lib (string->symbol (format "r~a" round)))])
          (rank-module! lib #t)
          (do ([i 0 (+ i 1)]) ((= i 20))
            (let ([owner (list-ref (list '(repl) '(init) lib) (random 3))]
                  [p (list-ref procedures (random 5))])
              (as-module owner
                (case (random 3)
                  [(0 1) (add-hook! changed p (list-ref '(-1 0 0 0.5 1) (random 5)))]
                  [else (remove-hook! changed p)]))))
          (when (fxzero? (random 10)) (take-back-changes! '(init) '()))
          (as-module lib (add-hook! changed (car procedures) 2))
          (let ([kept (hook-entries changed)])
            (move-before-importers! lib)
            (unless (equal? kept (hook-entries changed))
              (set! mismatches (+ mismatches 1))))
          (take-back-changes! lib '())))
      (check-equal? 0 mismatches)
      (for-each (lambda (owner) (take-back-changes! owner '())) '((repl) (init)))
      (check-equal? '() (hook-entries changed))))

  (test "a call on another thread runs each entry once, in order, while the main thread changes them"
    (let ([stop? #f] [bad '()] [calls 0] [mutex (make-mutex)])
      (define (caller)
        (fork-thread
          (lambda ()
            (let loop ([n 0])
              (if stop?
                  (with-mutex mutex (set! calls (+ calls n)))
                  (let ([seen (box '())])
                    (changed seen)
                    (let ([ran (reverse (unbox seen))])
                      (unless (equal? ran (list-sort < ran))
                        (with-mutex mutex (set! bad (cons ran bad)))))
                    (loop (+ n 1))))))))
      (let ([callers (list (caller) (caller) (caller))])
        (do ([i 0 (+ i 1)]) ((= i 5000))
          (for-each (lambda (m n) (add-hook! changed m n)) markers (iota 6))
          (for-each (lambda (m) (remove-hook! changed m)) (list-head markers (fxmod i 6))))
        (set! stop? #t)
        (for-each thread-join callers))
      (check-equal? '() bad)
      (check (> calls 0))
      (for-each (lambda (m) (remove-hook! changed m)) markers)
      (check-equal? '() (hook-entries changed))))

  (test "only the main thread changes hooks"
    (let ([s (make-scope)])
      (for-each
        (lambda (thunk) (check-equal? "only the main thread makes changes" (in-thread (lambda () (raised-message thunk)))))
        (list (lambda () (add-hook! changed car))
              (lambda () (remove-hook! changed car))
              (lambda () (parameterize ([current-scope s]) (add-local-hook! changed car)))
              (lambda () (define-hook elsewhere) elsewhere)))
      (check-equal? '() (hook-entries changed))
      (check-equal? '() (module-changes '(repl)))))

  (test "a collected scope's local entries are forgotten"
    (let ([kept (make-scope)])
      (let ([dropped (map (lambda (i) (make-scope)) (iota 100))])
        (for-each (lambda (s i) (parameterize ([current-scope s]) (add-local-hook! changed (marker i))))
                  dropped (iota 100))
        (parameterize ([current-scope kept]) (add-local-hook! changed (car markers)))
        (check-equal? 101 (length (module-changes '(repl))))
        ;; for-each lets go of each scope it passes, and a collection may
        ;; run before the count.
        (keep-live dropped))
      (do ([i 0 (+ i 1)]) ((= i 3)) (collect (collect-maximum-generation)))
      (parameterize ([current-scope kept]) (add-local-hook! changed (cadr markers) 1))
      (check-equal? 2 (length (module-changes '(repl))))
      (let ([seen (box '())])
        (parameterize ([current-scope kept]) (changed seen))
        (check-equal? '(1 0) (unbox seen)))
      (take-back-changes! '(repl) '())))

  (test "a quit never leaves a hook entry half made"
    (let ([s (make-scope)] [changing? #f] [quits-while-changing 0])
      (define (burn n) (if (fx= n 0) 0 (fx+ 1 (burn (fx- n 1)))))
      (do ([i 0 (+ i 1)]) ((= i 3000))
        (guard (c [(quit-condition? c)
                   (when changing? (set! quits-while-changing (+ quits-while-changing 1)))])
          (burn (random 1500))
          (request-quit!)
          (set! changing? #t)
          (do ([j 0 (fx+ j 1)]) ((fx= j 10))
            (add-hook! changed (car markers))
            (as-module '(init) (add-hook! changed (cadr markers)))
            (remove-hook! changed (cadr markers))
            (parameterize ([current-scope s])
              (add-local-hook! changed (caddr markers))
              (remove-local-hook! changed (caddr markers)))
            (remove-hook! changed (car markers)))
          (set! changing? #f)
          (let loop () (loop))))
      (check (> quits-while-changing 500))
      (for-each (lambda (owner) (take-back-changes! owner '())) '((repl) (init)))
      (check-equal? '() (hook-entries changed))
      (check-equal? '() (parameterize ([current-scope s]) (hook-entries changed)))
      (check-equal? '() (module-changes '(repl)))
      (check-equal? '() (module-changes '(init)))))

  ;; The advice on report asks for a second quit while the first is
  ;; reported, and lets it land after a random number of calls, so that
  ;; it falls anywhere from the report to the next entry, which runs long
  ;; enough to take it.
  (test "a quit requested while a quit is reported never escapes the hook"
    (let ([escaped 0] [asked? #f])
      (define (burn n) (if (fx= n 0) 0 (fx+ 1 (burn (fx- n 1)))))
      (define (ask-again report c)
        (when (and (quit-condition? c) (not asked?))
          (set! asked? #t)
          (request-quit!)
          (guard (q [(quit-condition? q) #f])
            (burn (random 1200)))))
      (define (runaway calls) (request-quit!) (let loop () (loop)))
      (define (long calls) (burn 3000))
      (add-hook! changed runaway)
      (add-hook! changed long 1)
      (advice-add! report ask-again)
      (do ([i 0 (+ i 1)]) ((= i 2000))
        (set! asked? #f)
        (guard (c [(quit-condition? c) (set! escaped (+ escaped 1))])
          (changed (box '()))))
      (advice-remove! report ask-again)
      (remove-hook! changed runaway)
      (remove-hook! changed long)
      (check-equal? 0 escaped))))

(post! (lambda ()
         (tests)
         (test-exit)))
(run-main-loop)
