(import (chezscheme) (tuna test) (tuna core changes) (tuna core modules)
        (except (tuna core main-thread) exit))

(define (in-thread thunk)
  (let ([result #f])
    (thread-join (fork-thread (lambda () (set! result (thunk)))))
    result))

(define (record! n)
  (record-change! 'test 'test n #f void void))

(define (record-all! things)
  (reverse (fold-left (lambda (cs n) (cons (record! n) cs)) '() things)))

(define (things owner)
  (map change-thing (filter (lambda (c) (eq? (change-kind c) 'test)) (owner-changes owner))))

(define (tests)
  (test "an owner's changes stay newest first whichever are taken back"
    (let ([changes (record-all! (iota 200))])
      (check-equal? (reverse (iota 200)) (things '(repl)))
      (let ([taken (filter (lambda (c) (or (memv (change-thing c) '(0 1 100 198 199)) (fxzero? (random 3))))
                           changes)])
        (for-each take-back! taken)
        (for-each forget-change! taken)
        (check-equal? (reverse (map change-thing (remp (lambda (c) (memq c taken)) changes)))
                      (things '(repl)))
        (check-equal? (map (lambda (c) (list 'test c #f)) (things '(repl)))
                      (module-changes '(repl))))
      (take-back-changes! '(repl) '())
      (check-equal? '() (module-changes '(repl)))))

  (test "a change records the current owner's own record"
    (let ([c (as-module '(init) (record! 'x))])
      (check (eq? (find-owner '(init)) (change-owner c)))
      (check-equal? '(init) (owner-name (change-owner c)))
      (take-back! c)
      (check-equal? '() (things '(init)))))

  (test "the configuration's, the REPL's and Tuna's ranks never change"
    (let ([before (map (lambda (name) (owner-rank (find-owner name))) '((tuna) (init) (repl)))])
      (for-each
        (lambda (name)
          (rank-module! name #t)
          (move-before-importers! name)
          (unrank-module! name))
        '((tuna) (init) (repl)))
      (check-equal? before (map (lambda (name) (owner-rank (find-owner name))) '((tuna) (init) (repl))))
      (check-equal? '(init) (as-module '(init) (this-module)))))

  (test "a module ranked again counts as loaded then, with the same owner"
    (rank-module! '(first) #f)
    (rank-module! '(second) #f)
    (let ([owner (find-owner '(first))])
      (as-module '(first) (record! 'kept))
      (unrank-module! '(first))
      (check (not (loaded-owner '(first))))
      (check-equal? "not a loaded module"
        (guard (c [(message-condition? c) (condition-message c)]) (as-module '(first) 'ran)))
      (rank-module! '(first) #f)
      (check (eq? owner (find-owner '(first))))
      (check (> (owner-rank owner) (owner-rank (find-owner '(second)))))
      (check-equal? '(kept) (things '(first)))
      (take-back-changes! '(first) '())))

  (test "a lib module moved out of the lib band reorders its changes"
    (rank-module! '(importer) #f)
    (rank-module! '(lib-module) #t)
    (check (> (owner-rank (find-owner '(lib-module))) (owner-rank (find-owner '(importer)))))
    (let ([reordered 0])
      (as-module '(lib-module) (record-change! 'test 'test 'r #f void (lambda () (set! reordered (+ reordered 1)))))
      (move-before-importers! '(lib-module))
      (check-equal? 1 reordered)
      (check (< (owner-rank (find-owner '(lib-module))) (expt 2 40)))
      (take-back-changes! '(lib-module) '())))

  (test "other threads look owners up while the main thread ranks modules"
    (let ([stop? #f] [bad 0] [mutex (make-mutex)])
      (define (reader)
        (fork-thread
          (lambda ()
            (let loop ([wrong 0])
              (if stop?
                  (with-mutex mutex (set! bad (+ bad wrong)))
                  (loop (if (equal? '(init) (as-module '(init) (this-module))) wrong (+ wrong 1))))))))
      (let ([readers (list (reader) (reader) (reader))])
        (do ([i 0 (+ i 1)]) ((= i 5000))
          (rank-module! (list 'ranked i) #f))
        (set! stop? #t)
        (for-each thread-join readers))
      (check-equal? 0 bad)
      (check (in-thread (lambda () (loaded-owner '(ranked 4999)))))))

  (test "a quit never leaves the ledger half changed"
    (let ([changing? #f] [quits-while-changing 0])
      (define (burn n) (if (fx= n 0) 0 (fx+ 1 (burn (fx- n 1)))))
      (do ([i 0 (+ i 1)]) ((= i 3000))
        (guard (c [(quit-condition? c)
                   (when changing? (set! quits-while-changing (+ quits-while-changing 1)))])
          (burn (random 1500))
          (request-quit!)
          (set! changing? #t)
          (let ([cs (record-all! (iota 40))])
            (for-each take-back! (filter (lambda (c) (fxeven? (change-thing c))) cs)))
          (set! changing? #f)
          (let loop () (loop))))
      (check (> quits-while-changing 500))
      (let ([sequences (map change-sequence (owner-changes '(repl)))])
        (check-equal? sequences (list-sort > sequences)))
      (take-back-changes! '(repl) '())
      (check-equal? '() (module-changes '(repl)))))

  (test "tasks taken back in any order leave the rest listed"
    (let ([tasks (map (lambda (i) (spawn-task (lambda () (suspend (lambda (resume) (void)))))) (iota 20000))])
      (check-equal? 20000 (length (module-changes '(repl))))
      (suspend (lambda (resume) (post! (lambda () (resume void)))))
      (let ([stopped (filter (lambda (t) (fxzero? (random 2))) tasks)])
        (for-each (lambda (t) (take-back! (find (lambda (c) (eq? (change-thing c) t)) (owner-changes '(repl)))))
                  (list-head stopped 100))
        (check-equal? (- 20000 100) (length (module-changes '(repl)))))
      (take-back-changes! '(repl) '())
      (check-equal? '() (module-changes '(repl))))))

(post! (lambda ()
         (tests)
         (test-exit)))
(run-main-loop)
