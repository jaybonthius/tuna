(import (chezscheme) (tuna-test) (lang loader) (lang language)
        (tuna core changes) (tuna core definitions) (tuna core modules)
        (except (tuna core main-thread) exit) (prefix (only (tuna core replaced) fork-thread dynamic-wind) tuna:))

(define root
  (let ([dir (format "/tmp/tuna-main-thread-test-~a" (get-process-id))])
    (mkdir dir)
    dir))

(define (write-library! name text)
  (call-with-output-file (string-append root "/lib/" name ".sls")
    (lambda (p) (put-string p text))))

(mkdir (string-append root "/lib"))
(write-library! "racer" "#!tuna\n(define (f x) (+ x 1))\n")

(compile-file-message #f)
(install-module-lookup! (library-directories) (string-append root "/lib") (string-append root "/library")
  (string-append root "/cache"))
(install-loader!)

(define main-thread-id (get-thread-id))

(define (sleep-ms ms)
  (sleep (make-time 'time-duration (* ms 1000000) 0)))

(define (wait-until-called receive-done)
  (suspend (lambda (resume) (receive-done (lambda () (resume void))))))

(define (raised-message thunk)
  (guard (c [#t (if (message-condition? c) (condition-message c) c)]) (thunk) #f))

(define (tests)
  (test "posts from many threads all run on the main thread, each thread's in order"
    (let ([seen '()] [finished 0] [threads 8] [posts 2000])
      (wait-until-called
        (lambda (done)
          (do ([i 0 (+ i 1)]) ((= i threads))
            (tuna:fork-thread
              (lambda ()
                (do ([n 0 (+ n 1)]) ((= n posts))
                  (post! (lambda () (set! seen (cons (list i n (get-thread-id)) seen)))))
                (post! (lambda ()
                         (set! finished (+ finished 1))
                         (when (= finished threads) (done)))))))))
      (check-equal? (* threads posts) (length seen))
      (check (for-all (lambda (s) (= (caddr s) main-thread-id)) seen))
      (check
        (for-all
          (lambda (i)
            (let ([ns (map cadr (filter (lambda (s) (= (car s) i)) (reverse seen)))])
              (equal? ns (iota posts))))
          (iota threads)))))

  (test "the items the loop takes at once are one batch, and what they post waits for the next"
    (let ([log '()] [outside '()])
      (define (note! e) (set! log (cons e log)))
      (define (ended batch-ended)
        (note! 'ended)
        (set! outside (cons (list (current-task) (current-owner)) outside))
        (batch-ended))
      (advice-add! batch-ended ended)
      (wait-until-called
        (lambda (done)
          (post! (lambda () (note! 'a) (post! (lambda () (note! 'c) (done)))))
          (post! (lambda () (note! 'b)))))
      (advice-remove! batch-ended ended)
      (check-equal? '(ended a b ended c ended) (reverse log))
      (check (for-all (lambda (seen) (equal? seen '(#f (tuna)))) outside))))

  ;; Allocation is deterministic, so the bound is loose only to leave room
  ;; for small changes; make bench holds the exact figure.
  (test "posting an item and running it allocates a few hundred bytes"
    (let ([n 100000] [start (sstats-bytes (statistics))])
      (wait-until-called
        (lambda (done)
          (do ([i 0 (+ i 1)]) ((= i n)) (post! void))
          (post! done)))
      (check (< (/ (- (sstats-bytes (statistics)) start) n) 400))))

  (test "when threads race to resume a task, one resumes it and the rest raise"
    (do ([trial 0 (+ trial 1)]) ((= trial 50))
      (let* ([resume #f]
             [task (spawn-task (lambda () (suspend (lambda (r) (set! resume r)))))]
             [refused 0]
             [refused-mutex (make-mutex)])
        (wait-until-called (lambda (done) (post! done)))
        (for-each thread-join
          (map (lambda (i)
                 (fork-thread
                   (lambda ()
                     (guard (c [(and (assertion-violation? c) (eq? (condition-who c) 'resume))
                                (with-mutex refused-mutex (set! refused (+ refused 1)))])
                       (resume (lambda () i))))))
               (iota 6)))
        (check-equal? 5 refused)
        (check (memv (join-task task) (iota 6))))))

  (test "a signal wins over a resume from another thread"
    (do ([trial 0 (+ trial 1)]) ((= trial 50))
      (let* ([resume #f]
             [task (spawn-task
                     (lambda ()
                       (guard (c [(eq? c 'signalled) c])
                         (suspend (lambda (r) (set! resume r))))))])
        (wait-until-called (lambda (done) (post! done)))
        (let ([resumer (fork-thread (lambda () (resume (lambda () 'resumed))))])
          (signal-task task 'signalled)
          (thread-join resumer))
        (check-equal? 'signalled (join-task task)))))

  (test "request-quit! from another thread interrupts the main thread's code"
    (do ([trial 0 (+ trial 1)]) ((= trial 20))
      (check-equal? 'quit
        (guard (c [(quit-condition? c) 'quit])
          (fork-thread (lambda () (sleep-ms 2) (request-quit!)))
          (let loop () (loop))))))

  (test "a request made while the main thread is idle quits nothing"
    (wait-until-called
      (lambda (done)
        (fork-thread
          (lambda ()
            (sleep-ms 20)
            (request-quit!)
            (done)))))
    (check-equal? 'finished
      (guard (c [(quit-condition? c) 'quit])
        (let loop ([n 0]) (if (fx= n 10000000) 'finished (loop (fx+ n 1)))))))

  (test "a raise on another thread is reported on the main thread and ends the thread"
    (let ([reports '()] [went-on? #f])
      (define (capture report c)
        (set! reports (cons (list (get-thread-id) (condition-who c)) reports)))
      (advice-add! report capture)
      (thread-join (fork-thread (lambda () (car 5) (set! went-on? #t))))
      (wait-until-called (lambda (done) (post! done)))
      (check-equal? (list (list main-thread-id 'car)) reports)
      (check (not went-on?))
      (thread-join (fork-thread (lambda () (warning 'careful "watch out") (set! went-on? #t))))
      (wait-until-called (lambda (done) (post! done)))
      (check-equal? (list main-thread-id 'careful) (car reports))
      (check went-on?)
      (advice-remove! report capture)))

  (test "a raise on another thread is reported as the owner that thread ran for"
    (let ([reports '()])
      (define (capture report c)
        (set! reports (cons (current-owner) reports)))
      (advice-add! report capture)
      (let ([threads (map (lambda (name)
                            (fork-thread (lambda () (call-as-owner (find-owner name) (lambda () (car 5))))))
                          '((init) (repl) (init) (tuna)))])
        (for-each thread-join threads))
      (wait-until-called (lambda (done) (post! done)))
      (advice-remove! report capture)
      (check-equal? '((init) (init) (repl) (tuna))
                    (list-sort (lambda (a b) (string<? (symbol->string (car a)) (symbol->string (car b))))
                               reports))))

  ;; Each round requests a quit after a random number of calls, so quits
  ;; land all over the changes and posts that follow; whatever they
  ;; interrupt, the change ledger and the definition agree afterwards, and
  ;; no mutex is left held. The round ends in a loop, so its quit always
  ;; lands inside the guard.
  (test "a quit never leaves a change half made"
    (let* ([env (environment '(chezscheme) '(tuna) '(racer))]
           [compiled (lambda (form) (eval form env))]
           [call-f (compiled '(lambda (x) (racer:f x)))]
           [advise! (compiled '(lambda (p) (advice-add! racer:f p)))]
           [unadvise! (compiled '(lambda (p) (advice-remove! racer:f p)))]
           [override! (compiled '(lambda (g) (set! racer:f g)))]
           [f-changes (compiled '(lambda () (definition-changes racer:f)))]
           [changing? #f]
           [quits-while-changing 0])
      (define (double f x) (* 2 (f x)))
      (define (plus-10 x) (+ x 10))
      (define (burn n) (if (fx= n 0) 0 (fx+ 1 (burn (fx- n 1)))))
      (do ([i 0 (+ i 1)]) ((= i 5000))
        (guard (c [(quit-condition? c)
                   (when changing? (set! quits-while-changing (+ quits-while-changing 1)))])
          (burn (random 1500))
          (request-quit!)
          (set! changing? #t)
          (do ([j 0 (fx+ j 1)]) ((fx= j 10))
            (advise! double)
            (override! plus-10)
            (unadvise! double)
            (post! void)
            (as-module '(init) (override! plus-10)))
          (set! changing? #f)
          (let loop () (loop))))
      (check (> quits-while-changing 1000))
      (thread-join (fork-thread request-quit!))
      (check (guard (c [(quit-condition? c) #t]) (let loop () (loop))))
      (unadvise! double)
      (for-each (lambda (owner) (take-back-changes! owner '())) '((repl) (init)))
      (check-equal? '(((racer) define #f)) (f-changes))
      (check-equal? '() (module-changes '(repl)))
      (check-equal? '() (module-changes '(init)))
      (check-equal? 2 (call-f 1))))

  (test "a quit never leaves a module half loaded or half unloaded"
    (write-library! "big"
      (call-with-string-output-port
        (lambda (p)
          (put-string p "#!tuna\n")
          (do ([i 0 (+ i 1)]) ((= i 300))
            (fprintf p "(define (f~a) ~a)\n" i i)))))
    (load-module! '(big))
    (let ([changing? #f] [quits-while-changing 0] [other-raises '()] [half-done 0])
      (do ([i 0 (+ i 1)]) ((= i 1000))
        (guard (c [(quit-condition? c)
                   (when changing? (set! quits-while-changing (+ quits-while-changing 1)))]
                  [#t (set! other-raises (cons c other-raises))])
          (let ([delay (random 3000000)])
            (fork-thread
              (lambda ()
                (sleep (make-time 'time-duration delay 0))
                (request-quit!))))
          (set! changing? #t)
          (if (module-loaded? '(big)) (unload-module! '(big)) (load-module! '(big)))
          (set! changing? #f)
          (let loop () (loop)))
        (set! changing? #f)
        (unless (= (length (module-changes '(big))) (if (module-loaded? '(big)) 300 0))
          (set! half-done (+ half-done 1))))
      (check-equal? '() other-raises)
      (check-equal? 0 half-done)
      ;; How many quits land depends on how the timer falls against the
      ;; definitions' disabled-interrupt regions, which any change to the
      ;; code on that path moves; the count ranges from about 60 to 300.
      (check (> quits-while-changing 20))
      (unless (module-loaded? '(big)) (load-module! '(big)))
      (check-equal? 300 (length (module-changes '(big))))))

  (test "only the main thread looks up a module or a plain library"
    (write-library! "elsewhere" "#!tuna\n(define (f) 1)\n")
    (write-library! "plain-elsewhere" "(library (plain-elsewhere) (export x) (import (chezscheme)) (define x 1))")
    (let ([messages '()])
      (thread-join
        (fork-thread
          (lambda ()
            (set! messages
              (map (lambda (name)
                     (raised-message
                       (lambda () (call-with-library-lock (lambda () (environment name))))))
                   '((elsewhere) (plain-elsewhere)))))))
      (check-equal? '("only the main thread makes changes" "a library is first loaded on the main thread") messages))
    (load-module! '(elsewhere))
    (check (module-loaded? '(elsewhere)))
    (check-equal? 1 (eval 'x (environment '(plain-elsewhere)))))

  (test "tick runs only on the main thread, and advice that raises is reported"
    (let ([ticks 0] [other-threads 0] [reported 0])
      (define (count tick)
        (if (= (get-thread-id) main-thread-id)
            (set! ticks (+ ticks 1))
            (set! other-threads (+ other-threads 1)))
        (when (= ticks 5) (error 'count "fifth tick"))
        (tick))
      (define (note report c) (set! reported (+ reported 1)))
      (advice-add! report note)
      (advice-add! tick count)
      (let ([worker (fork-thread (lambda () (let loop ([n 0]) (unless (fx= n 10000000) (loop (fx+ n 1))))))])
        (let loop ([n 0]) (unless (fx= n 10000000) (loop (fx+ n 1))))
        (thread-join worker))
      (advice-remove! tick count)
      (advice-remove! report note)
      (check (> ticks 100))
      (check-equal? 0 other-threads)
      (check-equal? 1 reported)))

  ;; Re-entering a paused task redoes its winders one at a time; the
  ;; outermost asks for a quit, and three hundred levels lie between it and
  ;; the guard, whose handler comes back last. Each level is a Tuna wind
  ;; and code that allows quits, as a hook entry does, around a Chez wind
  ;; that spends calls as it is redone, so the quit falls among the
  ;; winders.
  (test "a quit requested as a task resumes lands inside its handlers"
    (define (burn) (let loop ([i 0]) (when (< i 20) (loop (+ i 1)))))
    (define (nested n thunk)
      (if (= n 0)
          thunk
          (lambda ()
            (tuna:dynamic-wind void
              (lambda () (with-quits-allowed #t (dynamic-wind burn (nested (- n 1) thunk) void)))
              void))))
    (define (trial)
      (let ([entered 0])
        (tuna:dynamic-wind
          (lambda () (set! entered (+ entered 1)) (when (= entered 2) (request-quit!)))
          (nested 300
            (lambda ()
              (guard (c [(quit-condition? c) 'caught])
                (suspend (lambda (resume) (resume void)))
                (let spin ([i 0]) (if (< i 1000000) (spin (+ i 1)) 'not-quit)))))
          void)))
    (define (quiet report c) (unless (quit-condition? c) (report c)))
    (advice-add! report quiet)
    (let ([results (map (lambda (i) (guard (c [(quit-condition? c) 'killed]) (join-task (spawn-task trial))))
                        (iota 20))])
      (advice-remove! report quiet)
      (check-equal? (make-list 20 'caught) results)))

  ;; Leaving a task for the loop undoes its winders one at a time; the
  ;; innermost asks for a quit, and three hundred winds lie between it and
  ;; the guard.
  (test "a quit requested as a task pauses lands in no handler of the paused task"
    (define (nested n thunk)
      (if (= n 0) thunk (lambda () (tuna:dynamic-wind void (nested (- n 1) thunk) void))))
    (define (trial)
      (let ([asked #f])
        (guard (c [(quit-condition? c) 'caught])
          ((nested 300
             (lambda ()
               (tuna:dynamic-wind
                 void
                 (lambda () (suspend (lambda (resume) (resume void))) 'finished)
                 (lambda () (unless asked (set! asked #t) (request-quit!))))))))))
    (let ([results (map (lambda (i) (guard (c [(quit-condition? c) 'killed]) (join-task (spawn-task trial))))
                        (iota 20))])
      (check-equal? (make-list 20 'finished) results)))

  (test "quits from another thread never skip the guard of a task that pauses and resumes"
    (let ([finished 0] [caught 0] [open-winds 0] [tasks 400])
      (define (one)
        (guard (c [(quit-condition? c) (set! caught (+ caught 1))])
          (tuna:dynamic-wind
            (lambda () (set! open-winds (+ open-winds 1)))
            (lambda ()
              (do ([i 0 (+ i 1)]) ((= i 100))
                (suspend (lambda (resume) (resume void)))
                (let burn ([j 0]) (when (< j 2000) (burn (+ j 1))))))
            (lambda () (set! open-winds (- open-winds 1)))))
        (set! finished (+ finished 1)))
      (define (quiet report c) (unless (quit-condition? c) (report c)))
      (advice-add! report quiet)
      (wait-until-called
        (lambda (done)
          (do ([i 0 (+ i 1)]) ((= i tasks)) (spawn-task one))
          (tuna:fork-thread
            (lambda ()
              (let ([until (+ (real-time) 1000)])
                (let loop ()
                  (when (< (real-time) until)
                    (request-quit!)
                    (sleep (make-time 'time-duration 100000 0))
                    (loop))))
              (let wait ([n 0]) (unless (or (= finished tasks) (= n 500)) (sleep-ms 10) (wait (+ n 1))))
              (post! done)))))
      (advice-remove! report quiet)
      (check-equal? tasks finished)
      (check (> caught 0))
      (check-equal? 0 open-winds)))

  ;; The advice on report asks for a second quit while the first is
  ;; reported, and lets it land after a random number of calls, so that
  ;; it falls anywhere in the report and what follows it.
  (test "a quit requested while a quit is reported never escapes a task or module code"
    (let ([asked? #f] [unfinished 0] [escaped 0])
      (define (burn n) (if (fx= n 0) 0 (fx+ 1 (burn (fx- n 1)))))
      (define (ask-again report c)
        (when (and (quit-condition? c) (not asked?))
          (set! asked? #t)
          (request-quit!)
          (guard (q [(quit-condition? q) #f])
            (burn (random 1200)))))
      (define (runaway) (request-quit!) (let loop () (loop)))
      (advice-add! report ask-again)
      (do ([i 0 (+ i 1)]) ((= i 1000))
        (set! asked? #f)
        (let ([t (spawn-task runaway)])
          (wait-until-called (lambda (done) (post! done)))
          (unless (task-done? t) (set! unfinished (+ unfinished 1)))))
      (do ([i 0 (+ i 1)]) ((= i 1000))
        (set! asked? #f)
        (let ([in-module-code? #t])
          (guard (c [(quit-condition? c) (when in-module-code? (set! escaped (+ escaped 1)))])
            (with-quits-allowed #f
              (call-module-code runaway)
              (set! in-module-code? #f))
            (burn 3000))))
      (advice-remove! report ask-again)
      (check-equal? 0 unfinished)
      (check-equal? 0 escaped))))

(post! (lambda ()
         (tests)
         (system (format "rm -rf '~a'" root))
         (test-exit)))
(run-main-loop)
