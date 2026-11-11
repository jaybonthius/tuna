(import (chezscheme) (tuna-test) (tuna core changes) (tuna core definitions)
        (only (tuna core modules) take-back-changes!) (except (tuna core main-thread) exit)
        (tuna hooks) (tuna options) (prefix (only (tuna core replaced) fork-thread) tuna:))

(define (in-thread thunk)
  (let ([result #f])
    (thread-join (fork-thread (lambda () (set! result (thunk)))))
    result))

(define (burn n) (if (fx= n 0) 0 (fx+ 1 (burn (fx- n 1)))))

(define (let-waiting-tasks-run)
  (suspend (lambda (resume) (post! (lambda () (resume void))))))

(define-option level 0 fixnum?)
(define-hook ran)
(define-hook paused)
(define-hook reentered)

(define (state) (list (this-module) (level) (quits-allowed)))

(define reports '())

(define (note report c)
  (set! reports (cons (list (this-module) c) reports)))

(define (tests)
  (rank-module! '(a) #f)
  (rank-module! '(b) #f)

  (test "after a raise in an entry, the next entry runs as its owner with the caller's binding"
    (let ([seen #f])
      (as-module '(a) (add-hook! ran (lambda () (car '()))))
      (as-module '(b) (add-hook! ran (lambda () (set! seen (state)))))
      (set! reports '())
      (as-module '(init) (with-options ([level 1]) (ran)))
      (check-equal? '((b) 1 #t) seen)
      (check-equal? '((a)) (map car reports))
      (check-equal? '((repl) 0 #t) (state))
      (take-back-changes! '(a) '())
      (take-back-changes! '(b) '())))

  (test "a warning in an entry is reported once, and the entry goes on as its owner"
    (let ([after #f])
      (as-module '(a) (add-hook! ran (lambda () (warning 'entry "careful") (set! after (this-module)))))
      (set! reports '())
      (ran)
      (check-equal? '(a) after)
      (check-equal? '((a)) (map car reports))
      (take-back-changes! '(a) '())))

  ;; Each round requests a quit after a random number of calls, so quits
  ;; land all over hook entries of another owner, as-module and
  ;; with-options, their winders included.
  (test "a quit never leaves an owner, a binding or quits-allowed switched"
    (let ([caught 0] [in-guard 0] [bad 0])
      (define (entry j)
        (with-options ([level 1])
          (as-module '(repl)
            (with-options ([level 2])
              (burn 20)))))
      (as-module '(init) (add-hook! ran entry))
      (set! reports '())
      (do ([i 0 (+ i 1)]) ((= i 5000))
        (let ([before (length reports)])
          (guard (c [(quit-condition? c) (set! in-guard (+ in-guard 1))])
            (burn (random 1500))
            (request-quit!)
            (do ([j 0 (fx+ j 1)]) ((fx= j 10))
              (ran j)
              (with-options ([level 3]) (as-module '(init) (burn 5))))
            (when (= (length reports) before) (let loop () (loop)))))
        (unless (equal? '((repl) 0 #t) (state))
          (set! bad (+ bad 1))))
      (set! caught (length (filter (lambda (r) (quit-condition? (cadr r))) reports)))
      (check (> caught 1000))
      (check (> in-guard 100))
      (check-equal? 0 bad)
      (take-back-changes! '(init) '())))

  (test "a task paused in an entry goes on as the entry's owner with its binding, and can be quit"
    (let ([resume-entry #f] [in-entry #f] [after #f] [meanwhile #f])
      (as-module '(a)
        (add-hook! paused
          (lambda ()
            (suspend (lambda (resume) (set! resume-entry resume)))
            (set! in-entry (state))
            (request-quit!)
            (let loop () (loop)))))
      (set! reports '())
      (as-module '(b)
        (spawn-task
          (lambda ()
            (with-options ([level 20]) (paused))
            (set! after (state)))))
      (let-waiting-tasks-run)
      (as-module '(init) (spawn-task (lambda () (set! meanwhile (state)))))
      (let-waiting-tasks-run)
      (check-equal? '((init) 0 #t) meanwhile)
      (check-equal? '((repl) 0 #t) (state))
      (resume-entry void)
      (let-waiting-tasks-run)
      (check-equal? '((a) 20 #t) in-entry)
      (check-equal? '((b) 0 #t) after)
      (check-equal? '((a)) (map car reports))
      (check (quit-condition? (cadar reports)))
      (take-back-changes! '(a) '())
      (take-back-changes! '(b) '())))

  (test "a forked thread starts with its parent's owner and no bindings, and its switches stay its own"
    (check-equal? '((a) 0 #f)
      (as-module '(a) (with-options ([level 5]) (in-thread state))))
    (let ([stop? #f] [leaked 0] [child-bad 0])
      (let ([child (fork-thread
                     (lambda ()
                       (let loop ()
                         (unless stop?
                           (as-module '(b)
                             (with-options ([level 7])
                               (unless (equal? '((b) 7) (list (this-module) (level)))
                                 (set! child-bad (+ child-bad 1)))))
                           (loop)))))])
        (do ([i 0 (+ i 1)]) ((= i 20000))
          (as-module '(a)
            (with-options ([level 3])
              (unless (equal? '((a) 3) (list (this-module) (level)))
                (set! leaked (+ leaked 1)))))
          (unless (equal? '((repl) 0) (list (this-module) (level)))
            (set! leaked (+ leaked 1))))
        (set! stop? #t)
        (thread-join child))
      (check-equal? 0 leaked)
      (check-equal? 0 child-bad)))

  (test "Tuna's fork-thread gives the child the owner at the fork; Chez's, the parent's when the child first needs one"
    (let ([go #f] [seen #f])
      (let ([child (as-module '(a)
                     (with-options ([level 5])
                       (tuna:fork-thread
                         (lambda ()
                           (let loop () (unless go (loop)))
                           (set! seen (state))))))])
        (as-module '(b)
          (set! go #t)
          (thread-join child)))
      (check-equal? '((a) 0 #f) seen))
    (let ([go #f] [seen #f])
      (let ([child (as-module '(a)
                     (fork-thread
                       (lambda ()
                         (let loop () (unless go (loop)))
                         (set! seen (this-module)))))])
        (as-module '(b)
          (set! go #t)
          (thread-join child)))
      (check-equal? '(b) seen)))

  (test "a thread slot's binding is the innermost, holds only on its own thread, and goes on an escape"
    (let* ([a (make-thread-slot)]
           [b (car (reverse (map (lambda (i) (make-thread-slot)) (iota 20))))])
      (define (now) (list (thread-slot-ref a 'none) (thread-slot-ref b 'none)))
      (check-equal? '(none none) (now))
      (call-with-thread-slot a 1
        (lambda ()
          (call-with-thread-slot a 2
            (lambda ()
              (check-equal? '(2 none) (now))
              (check-equal? '(none none) (in-thread now))))
          (check-equal? '(1 none) (now))
          (check-equal? 'out (call/cc (lambda (k) (call-with-thread-slot b 3 (lambda () (k 'out))))))
          (check-equal? '(1 none) (now))
          (call-with-thread-slot b #f (lambda () (check-equal? '(1 #f) (now))))))
      (check-equal? '(none none) (now))))

  (test "an escape and a guard put back the owner and the binding"
    (check-equal? 'out
      (call/cc (lambda (k) (as-module '(a) (with-options ([level 3]) (k 'out))))))
    (check-equal? '((repl) 0 #t) (state))
    (check-equal? '((repl) 0)
      (guard (c [#t (list (this-module) (level))])
        (as-module '(a) (with-options ([level 3]) (raise 'out)))))
    (check-equal? '((repl) 0 #t) (state)))

  (test "an entry's continuation re-entered after its hook has returned runs as its owner with its binding"
    (let ([k #f] [seen '()] [again? #f])
      (as-module '(a)
        (add-hook! reentered
          (lambda ()
            (call/cc (lambda (c) (set! k c)))
            (set! seen (cons (state) seen)))))
      (with-options ([level 2]) (reentered))
      (check-equal? '((repl) 0 #t) (state))
      (unless again?
        (set! again? #t)
        (k #f))
      (check-equal? '(((a) 2 #t) ((a) 2 #t)) seen)
      (check-equal? '((repl) 0 #t) (state))
      (take-back-changes! '(a) '()))))

(advice-add! report note)
(post! (lambda ()
         (tests)
         (test-exit)))
(run-main-loop)
