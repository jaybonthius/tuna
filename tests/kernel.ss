(import (tuna) (test) (test-runner)
        (rename (only (chezscheme) sleep fork-thread) (sleep chez:sleep) (fork-thread chez:fork-thread))
        (only (tuna core kernel) tuna-register-signal-handler call-reporting))

;; The kernel reports the end of every task a cancel ends, and these tests
;; cancel hundreds; any other report still fails the file.
(advice-add! report (lambda (next c) (unless (cancelled? c) (next c))))

(define (sleep-ms ms)
  (chez:sleep (make-time 'time-duration (* (mod ms 1000) 1000000) (quotient ms 1000))))

;; The main thread's sleep would block every task; a thread's sleep pauses
;; only the task that waits for it.
(define (pause-ms ms)
  (suspend (lambda (resume) (fork-task (lambda (restore) (sleep-ms ms) (resume void))))))

;; Chez finds a module stale when its source is newer than its object, and
;; file times step with the kernel's clock tick, 1 to 10 ms, so a rewrite
;; in the tick of the last compile would look unchanged.
(define (next-file-tick) (pause-ms 10))

;; The main thread is busy on purpose while a thread waits for it, so the
;; thread keeps the deadline: on a miss it cancels the busy task with the
;; reason missed, which its test then sees instead of hanging.
(define (wait-on-thread done? busy)
  (let ([deadline (add-duration (current-time 'time-monotonic) (make-time 'time-duration 0 30))])
    (let loop ()
      (cond
        [(done?) #t]
        [(time>? (current-time 'time-monotonic) deadline) (cancel-task busy 'missed) #f]
        [else (sleep-ms 1) (loop)]))))

(define (done? t) (eq? (task-state t) 'done))

(define (ended t) (call-with-values (lambda () (join-task t)) list))

(define (spin) (let loop () (loop)))

(define (spin-for n) (let loop ([i 0]) (when (fx< i n) (loop (fx+ i 1)))))

(define (load-named name) (load-module! name))

(define (owner-of name) (module-owner name))

(define (write-module! name text)
  (let ([path (string-append (getenv "HOME") "/.config/tuna/lib/" name ".sls")])
    (when (file-exists? path) (delete-file path))
    (call-with-output-file path (lambda (p) (put-string p text)))))

;; A test changes things only as an owner of its own, since the kernel
;; makes no change itself.
(define as-test-owner
  (let ([owner #f])
    (lambda (thunk)
      (unless (and owner (owner-live? owner)) (set! owner (make-owner '(test))))
      (call-as-owner owner thunk))))

(define (test-owner) (as-test-owner current-owner))

(define main-thread (get-thread-id))

(define (on-main) (eqv? (get-thread-id) main-thread))

(define kill (begin (load-shared-object "libc.so.6") (foreign-procedure "kill" (int int) int)))

(define (send-signal! sig) (kill (get-process-id) sig))

(define (bump! b) (let retry () (let ([n (unbox b)]) (unless (box-cas! b n (+ n 1)) (retry)))))

(test "a cancel reaches the task it names and no other"
  (let* ([a (spawn-task (lambda (restore) (spin)))]
         [b-ran 0]
         [b (spawn-task (lambda (restore) (let loop () (set! b-ran (+ b-ran 1)) (pause-ms 1) (loop))))])
    (fork-task (lambda (restore) (sleep-ms 20) (cancel-task a 'mine)))
    (check-equal? '(cancelled mine) (ended a))
    (let ([before b-ran])
      (pause-ms 20)
      (check (not (done? b)))
      (check (> b-ran before)))
    (stop-task b)
    (check-equal? '(stopped #f) (ended b))))

(test "a cancel to a paused task raises at its pause, and to a queued one ends it unstarted"
  (let* ([paused (spawn-task (lambda (restore) (guard (c [(cancelled? c) (list 'caught (cancelled-reason c))]) (suspend (lambda (resume) (void))))))]
         [queued (spawn-task (lambda (restore) 'ran))])
    (cancel-task queued 'early)
    (pause-ms 5)
    (cancel-task paused 'late)
    (check-equal? '(returned ((caught late))) (ended paused))
    (check-equal? '(cancelled early) (ended queued))))

(test "a mask holds a cancel off, and restore or the mask's end lets it in"
  (let* ([log '()]
         [phase (box 0)]
         [t (spawn-task
              (lambda (restore)
                (call-with-cancellation-masked
                  (lambda (restore)
                    (set-box! phase 1)
                    (spin-for 50000000)
                    (set! log (cons 'masked-work-done log))
                    (guard (c [(cancelled? c) (set! log (cons 'restore-let-it-in log))])
                      (restore void))
                    (set-box! phase 2)
                    (spin-for 50000000)
                    (set! log (cons 'second-masked-work-done log))))
                (set! log (cons 'after-mask log))
                (spin)))])
    (fork-task
      (lambda (restore)
        (when (wait-on-thread (lambda () (= (unbox phase) 1)) t)
          (cancel-task t 'one)
          (when (wait-on-thread (lambda () (= (unbox phase) 2)) t)
            (cancel-task t 'two)))))
    (check-equal? '(cancelled two) (ended t))
    (check-equal? '(masked-work-done restore-let-it-in second-masked-work-done after-mask) (reverse log))))

(test "code that holds no restore of its caller's mask never unmasks the caller"
  (let ([t (spawn-task
             (lambda (restore)
               (call-with-cancellation-masked
                 (lambda (outer)
                   (call-with-cancellation-masked
                     (lambda (inner)
                       (inner (lambda () (spin-for 20000000)))))
                   'masked-to-the-end))))])
    (fork-task (lambda (restore) (sleep-ms 5) (cancel-task t)))
    (check-equal? '(returned (masked-to-the-end)) (ended t))))

(test "a task spawned from masked code starts masked, and its restore unmasks it"
  (let* ([started (call-with-cancellation-masked
                    (lambda (restore)
                      (spawn-task
                        (lambda (restore)
                          (spin-for 20000000)
                          (restore (lambda () (spin)))))))])
    (fork-task (lambda (restore) (sleep-ms 1) (cancel-task started 'x)))
    (check-equal? '(cancelled x) (ended started))))

(test "a stop lands through masks and handlers, and its winders run masked"
  (let* ([log '()]
         [t (spawn-task
              (lambda (restore)
                (call-with-cancellation-masked
                  (lambda (restore)
                    (dynamic-wind
                      void
                      (lambda () (guard (c [#t (set! log (cons 'caught log))]) (spin)))
                      (lambda () (set! log (cons 'winder log))))))))])
    (fork-task (lambda (restore) (sleep-ms 5) (stop-task t)))
    (check-equal? '(stopped #f) (ended t))
    (check-equal? '(winder) log)))

(test "a cancel and a stop reach a thread's task"
  (let ([c (fork-task (lambda (restore) (spin)))]
        [s (fork-task (lambda (restore) (call-with-cancellation-masked (lambda (restore) (spin)))))])
    (cancel-task c 'thread)
    (stop-task s)
    (check-equal? '(cancelled thread) (ended c))
    (check-equal? '(stopped #f) (ended s))))

(test "when threads race to resume a task, one resumes it and the rest raise"
  (do ([trial 0 (+ trial 1)]) ((= trial 30))
    (let* ([resume #f]
           [task (spawn-task (lambda (restore) (suspend (lambda (r) (set! resume r)))))]
           [refused (box 0)])
      (pause-ms 1)
      (for-each (lambda (t) (join-task t))
        (map (lambda (i)
               (fork-task
                 (lambda (restore)
                   (guard (c [(and (assertion-violation? c) (eq? (condition-who c) 'resume))
                              (let retry () (let ([n (unbox refused)]) (unless (box-cas! refused n (+ n 1)) (retry))))])
                     (resume (lambda () i))))))
             (iota 6)))
      (check-equal? 5 (unbox refused))
      (let ([e (ended task)])
        (check (and (eq? (car e) 'returned) (memv (caadr e) (iota 6))))))))

(test "a raise on another thread is reported on the main thread"
  (letrec ([seen #f] [quiet (lambda (next c) (set! seen (on-main)))])
    (as-test-owner (lambda () (advice-add! report quiet)))
    (let ([t (as-test-owner (lambda () (fork-task (lambda (restore) (error 'thread "from a thread")))))])
      (check-equal? 'raised (car (ended t)))
      (test-runner:wait-until (lambda () seen))
      (check-equal? #t seen))
    (as-test-owner (lambda () (advice-remove! report quiet)))))

(test "an unloaded module leaves no task, thread or code of its own running"
  (write-module! "stale"
    (string-append
      "#!tuna\n"
      "(define log '())\n"
      "(define (note! x) (set! %log (cons x %log)))\n"
      "(define %log '())\n"
      "(define (entries) %log)\n"
      "(define (enter wait) (wait))\n"
      "(spawn-task (lambda (restore) (let loop () (suspend (lambda (resume) (resume void))) (loop))))\n"
      "(spawn-task (lambda (restore) (suspend (lambda (resume) (void)))))\n"
      "(fork-task (lambda (restore) (let loop () (loop))))\n"))
  (let* ([stale (load-named '(stale))]
         [enter (eval 'stale:enter (environment '(stale)))]
         [outcome #f]
         [caller (spawn-task
                   (lambda (restore)
                     (set! outcome
                       (guard (c [(unloaded? c) (list 'unloaded (owner-name (unloaded-owner c)))])
                         (call-as-owner stale
                           (lambda () (enter (lambda () (suspend (lambda (resume) (void)))))))))))])
    (pause-ms 5)
    (let ([own (filter (lambda (t) (eq? (task-owner t) stale)) (live-tasks))])
      (check-equal? 3 (length own))
      (unload-owner! stale)
      (check (not (owner-live? stale)))
      (check (for-all done? own))
      (check (not (exists (lambda (t) (eq? (task-owner t) stale)) (live-tasks))))
      (test-runner:wait-until (lambda () outcome))
      (check-equal? '(unloaded (stale)) outcome)
      (check-equal? 'returned (car (ended caller))))))

(test "an unload's actions run while its threads still run, so the last write lands"
  (write-module! "writer"
    (string-append
      "#!tuna\n"
      "(define %m (make-mutex))\n"
      "(define %c (make-condition))\n"
      "(define %queue (box '()))\n"
      "(define %finish (box #f))\n"
      "(define (%write! x) (putprop 'kernel-test 'written (cons x (getprop 'kernel-test 'written '()))))\n"
      "(define (put! x) (with-mutex %m (set-box! %queue (append (unbox %queue) (list x))) (condition-signal %c)))\n"
      "(define %thread\n"
      "  (fork-task\n"
      "    (lambda (restore)\n"
      "      (let loop ()\n"
      "        (let ([x (with-mutex %m\n"
      "                   (let wait ()\n"
      "                     (cond\n"
      "                       [(pair? (unbox %queue)) (let ([x (car (unbox %queue))]) (set-box! %queue (cdr (unbox %queue))) x)]\n"
      "                       [(unbox %finish) #f]\n"
      "                       [else (condition-wait %c %m) (wait)])))])\n"
      "          (when x (sleep (make-time 'time-duration 2000000 0)) (%write! x) (loop)))))))\n"
      "(on-unload (lambda () (with-mutex %m (set-box! %finish #t) (condition-signal %c)) (join-task %thread)))\n"))
  (let* ([writer (load-named '(writer))] [env (environment '(writer))]
         [put! (eval 'writer:put! env)])
    (for-each put! '(1 2 3 last))
    (unload-owner! writer)
    (check-equal? '(last 3 2 1) (getprop 'kernel-test 'written '()))))

(test "a reload of unchanged code gives the value before"
  (write-module! "base" "#!tuna\n(define (f) 'base)\n")
  (write-module! "upper" "#!tuna\n(import (base))\n(advice-add! base:f (lambda (next) (list 'upper (next))))\n")
  (load-named '(upper))
  (let ([f (eval 'base:f (environment '(base)))])
    (as-test-owner (lambda () (advice-add! f (lambda (next) (list 'test (next))))))
    (let ([before (f)])
      (check-equal? '(test (upper base)) before)
      (reload-modules! '((base)))
      (check-equal? before (f))
      (reload-modules! '((upper)))
      (check-equal? before (f))
      (as-test-owner (lambda () (override-remove! f)))
      (check-equal? before (f)))))

(test "an override counts whatever its owner's rank, and a removal by a higher rank brings the definition back"
  (write-module! "defines" "#!tuna\n(define (g) 'defined)\n")
  (load-named '(defines))
  (let ([g (eval 'defines:g (environment '(defines)))])
    (write-module! "overrides" "#!tuna\n(import (defines))\n(override-set! defines:g (lambda () 'overridden))\n")
    (load-named '(overrides))
    (check-equal? 'overridden (g))
    (as-test-owner (lambda () (override-remove! g)))
    (check-equal? 'defined (g))
    (reload-modules! '((overrides)))
    (check-equal? 'defined (g))
    (unload-owner! (test-owner))
    (check-equal? 'overridden (g))))

(test "under advice, the definition and the inner advice see the procedure's caller, and each advice its owner"
  (write-module! "recorder" "#!tuna\n(define (who) (current-owner))\n")
  (load-named '(recorder))
  (let ([who (eval 'recorder:who (environment '(recorder)))]
        [first (make-owner '(advice first))] [second (make-owner '(advice second))] [caller (make-owner '(caller))]
        [seen '()])
    (define (noting name) (lambda (next) (set! seen (cons (list name (current-owner)) seen)) (next)))
    (call-as-owner first (lambda () (advice-add! who (noting 'first))))
    (call-as-owner second (lambda () (advice-add! who (noting 'second))))
    (check-equal? caller (call-as-owner caller who))
    (check-equal? 2 (length seen))
    (check (member (list 'first first) seen))
    (check (member (list 'second second) seen))
    (for-each unload-owner! (list first second caller))))

;; A call already inside an adviser's code when its unload begins may
;; raise &unloaded; one that starts once the unload has begun never
;; enters the adviser's layer, so never raises. The unload action runs
;; after the unload's first step, so it marks a moment after it.
(test "a call that starts once an adviser's unload has begun never raises &unloaded"
  (write-module! "callee" "#!tuna\n(define (h x) (+ x 1))\n")
  (load-named '(callee))
  (let ([h (eval 'callee:h (environment '(callee)))] [late (box 0)] [calls (box 0)] [stop? (box #f)]
        [unloads (make-eq-hashtable)] [m (make-mutex)] [unloads-begun (box 0)])
    (define (bump! b) (let retry () (let ([n (unbox b)]) (unless (box-cas! b n (+ n 1)) (retry)))))
    (let ([callers
           (map (lambda (i)
                  (fork-task
                    (lambda (restore)
                      (let loop ()
                        (unless (unbox stop?)
                          (let ([started (unbox unloads-begun)])
                            (guard (c [(unloaded? c)
                                       (when (with-mutex m (<= (hashtable-ref unloads (unloaded-owner c) (+ started 1)) started))
                                         (bump! late))])
                              (let ([v (h 1)]) (unless (memv v '(2 102)) (error 'race "wrong value" v)))))
                          (bump! calls)
                          (loop))))))
                (iota 3))])
      (do ([i 0 (+ i 1)]) ((= i 200))
        (let ([o (make-owner (list 'adviser (string->symbol (number->string i))))])
          (call-as-owner o
            (lambda ()
              (advice-add! h (lambda (next x) (+ 100 (next x))))
              (on-unload
                (lambda ()
                  (let ([n (+ (unbox unloads-begun) 1)])
                    (with-mutex m (hashtable-set! unloads o n))
                    (set-box! unloads-begun n))))))
          (pause-ms 0)
          (unload-owner! o)))
      (set-box! stop? #t)
      (for-each (lambda (t) (check-equal? 'returned (car (ended t)))) callers)
      (check (> (unbox calls) 0))
      (check-equal? 0 (unbox late)))))

(test "a cancel never leaves a change to a definition half made"
  (write-module! "racer" "#!tuna\n(define (f x) (+ x 1))\n")
  (load-named '(racer))
  (let ([f (eval 'racer:f (environment '(racer)))] [cancelled 0] [o (make-owner '(racer changer))])
    (define (double f x) (* 2 (f x)))
    (define (plus-10 x) (+ x 10))
    (do ([i 0 (+ i 1)]) ((= i 300))
      (let ([t (spawn-task
                 (lambda (restore)
                   (call-as-owner o
                     (lambda ()
                       (let loop ()
                         (advice-add! f double)
                         (override-set! f plus-10)
                         (advice-remove! f double)
                         (override-remove! f)
                         (loop))))))])
        (fork-task (lambda (restore) (sleep-ms (random 3)) (cancel-task t)))
        (let-values ([(how detail) (join-task t)])
          (when (eq? how 'cancelled) (set! cancelled (+ cancelled 1))))))
    (check (> cancelled 250))
    (unload-owner! o)
    (check-equal? '(define) (map cadr (definition-changes f)))
    (check-equal? 2 (f 1))))

(test "operations run one at a time, though their clean-up pauses"
  (write-module! "slow"
    (string-append
      "#!tuna\n"
      "(define (%note! x) (putprop 'kernel-test 'log (cons x (getprop 'kernel-test 'log '()))))\n"
      "(%note! 'loaded)\n"
      "(on-unload (lambda () (%note! 'unload-begins) (suspend (lambda (resume) (resume void))) (%note! 'unload-ends)))\n"))
  (load-named '(slow))
  (let* ([one (spawn-task (lambda (restore) (reload-modules! '((slow)))))]
         [two (spawn-task (lambda (restore) (reload-modules! '((slow)))))])
    (join-task one)
    (join-task two)
    (check-equal? '(loaded unload-begins unload-ends loaded unload-begins unload-ends loaded)
                  (reverse (getprop 'kernel-test 'log '())))))

(test "a call of an operation from a clean-up task raises"
  (write-module! "cleaner"
    "#!tuna\n(on-unload (lambda () (putprop 'kernel-test 'cleaner (guard (c [(violation? c) 'refused]) (load-module! '(slow)) 'loaded))))\n")
  (let ([cleaner (load-named '(cleaner))])
    (unload-owner! cleaner)
    (check-equal? 'refused (getprop 'kernel-test 'cleaner #f))))

(test "an owner made again keeps its name's rank, above every module"
  (let* ([a (make-owner '(made a))])
    (unload-owner! a)
    (write-module! "later" "#!tuna\n(define x 1)\n")
    (load-named '(later))
    (let ([a2 (make-owner '(made a))])
      (check (owner<? (owner-of '(later)) a2))
      (check (not (owner<? a a2)))
      (check (not (owner<? a2 a)))
      (unload-owner! a2))))

(test "a module ranks above every module it imports, after a reload that adds an import"
  (write-module! "early" "#!tuna\n(define (x) 1)\n")
  (load-named '(early))
  (write-module! "late" "#!tuna\n(define (y) 2)\n")
  (load-named '(late))
  (check (owner<? (owner-of '(early)) (owner-of '(late))))
  (next-file-tick)
  (write-module! "early" "#!tuna\n(import (late))\n(define (x) (late:y))\n")
  (reload-modules! '((early)))
  (check (owner<? (owner-of '(late)) (owner-of '(early)))))

(test "a body that raises unloads its instance, and a failed reload restores the set"
  (write-module! "flaky" "#!tuna\n(define (v) 'first)\n")
  (load-named '(flaky))
  (let ([v (eval 'flaky:v (environment '(flaky)))] [first (owner-of '(flaky))])
    (next-file-tick)
    (write-module! "flaky" "#!tuna\n(define (v) 'second)\n(error 'flaky \"broken body\")\n")
    (check-raises error? (reload-modules! '((flaky))))
    (check-equal? 'first (v))
    (check (owner-live? (owner-of '(flaky))))
    (check (not (eq? first (owner-of '(flaky)))))))

(test "exit-anyway? and owner-unloading can be advised"
  (let ([unloading '()] [o (make-owner '(advised))])
    (define (no next c) #f)
    (define (note next owner) (set! unloading (cons owner unloading)) (next owner))
    (as-test-owner (lambda () (advice-add! exit-anyway? no) (advice-add! owner-unloading note)))
    (check-equal? #f (exit-anyway? (make-message-condition "leaving")))
    (unload-owner! o)
    (check (memq o unloading))
    (as-test-owner (lambda () (advice-remove! exit-anyway? no) (advice-remove! owner-unloading note)))
    (check-equal? #t (exit-anyway? (make-message-condition "leaving")))))

(test "tasks spawned from many threads all run on the main thread, each thread's in order"
  (let ([seen '()] [threads 4] [spawns 500] [m (make-mutex)])
    (for-each join-task
      (map (lambda (i)
             (as-test-owner
               (lambda ()
                 (fork-task
                   (lambda (restore)
                     (do ([n 0 (+ n 1)]) ((= n spawns))
                       (spawn-task (lambda (restore) (set! seen (cons (list i n (on-main)) seen))))))))))
           (iota threads)))
    (test-runner:wait-until (lambda () (= (length seen) (* threads spawns))))
    (check (for-all caddr seen))
    (check (for-all (lambda (i)
                      (equal? (iota spawns) (map cadr (filter (lambda (s) (= (car s) i)) (reverse seen)))))
                    (iota threads)))))

(test "batch-ended runs in a task of its own once the loop has run what it took at once"
  (let ([log '()])
    (define (ended next) (set! log (cons (list 'ended (and (current-task) #t)) log)) (next))
    (as-test-owner (lambda () (advice-add! batch-ended ended)))
    (pause-ms 5)
    (check (pair? log))
    (check (for-all cadr log))
    (as-test-owner (lambda () (advice-remove! batch-ended ended)))))

(test "a cancel wins over a resume from another thread"
  (do ([trial 0 (+ trial 1)]) ((= trial 30))
    (let* ([resume #f]
           [task (spawn-task
                   (lambda (restore)
                     (guard (c [(cancelled? c) 'cancelled])
                       (suspend (lambda (r) (set! resume r))))))])
      (pause-ms 1)
      (cancel-task task)
      (join-task (fork-task (lambda (restore) (resume (lambda () 'resumed)))))
      (check-equal? '(returned (cancelled)) (ended task)))))

(test "tick runs only on the main thread, masked, and advice that raises is reported"
  (let ([ticks 0] [off-main 0] [reported 0])
    (define (count next)
      (if (on-main) (set! ticks (+ ticks 1)) (set! off-main (+ off-main 1)))
      (next))
    (define (fail next) (error 'tick "advice failed"))
    (define (quiet next c) (set! reported (+ reported 1)))
    (as-test-owner (lambda () (advice-add! tick count) (advice-add! report quiet)))
    (join-task (fork-task (lambda (restore) (spin-for 10000000))))
    (spin-for 10000000)
    (check (> ticks 0))
    (check-equal? 0 off-main)
    (as-test-owner (lambda () (advice-add! tick fail)))
    (spin-for 1000000)
    (as-test-owner (lambda () (advice-remove! tick fail) (advice-remove! tick count) (advice-remove! report quiet)))
    (check (> reported 0))))

(test "a forked thread acts as its forker; a thread Chez forked acts for no owner and can neither change nor spawn"
  (let ([forker-owner (as-test-owner current-owner)])
    (check-equal? forker-owner (as-test-owner (lambda () (let ([o #f]) (join-task (fork-task (lambda (restore) (set! o (current-owner))))) o))))
    (let ([outcome #f] [m (make-mutex)] [c (make-condition)] [done #f])
      (chez:fork-thread
        (lambda ()
          (let ([r (list (current-owner)
                         (guard (e [(assertion-violation? e) 'refused]) (spawn-task (lambda (restore) 1)))
                         (guard (e [(assertion-violation? e) 'refused]) (on-unload void)))])
            (with-mutex m (set! outcome r) (set! done #t) (condition-signal c)))))
      (test-runner:wait-until (lambda () (with-mutex m done)))
      (check-equal? '(#f refused refused) outcome))))

(test "an escape or a raise out of code entered as an owner puts back the caller's owner"
  (let ([o (make-owner '(frames))] [before (current-owner)])
    (call/cc (lambda (k) (call-as-owner o (lambda () (k 'escaped)))))
    (check-equal? before (current-owner))
    (guard (c [#t (void)]) (call-as-owner o (lambda () (error 'frames "raised"))))
    (check-equal? before (current-owner))
    (check-equal? o (call-as-owner o current-owner))
    (unload-owner! o)
    (check-raises unloaded? (call-as-owner o void))))

(test "loading, unloading and reloading from a thread that is not a task raise and change nothing"
  (write-module! "far" "#!tuna\n(define (f) 1)\n")
  (load-named '(far))
  (let ([results #f] [m (make-mutex)] [done #f])
    (chez:fork-thread
      (lambda ()
        (let ([r (map (lambda (thunk) (guard (e [(violation? e) 'refused]) (thunk) 'ran))
                      (list (lambda () (unload-owner! (module-owner '(far))))
                            (lambda () (reload-modules! '((far))))
                            (lambda () (load-module! '(stillborn)))))])
          (with-mutex m (set! results r) (set! done #t)))))
    (test-runner:wait-until (lambda () (with-mutex m done)))
    (check-equal? '(refused refused refused) results)
    (check (owner-live? (module-owner '(far))))))

(test "an owner's changes are listed newest first, and an unload takes them all back"
  (let ([o (make-owner '(ledger))] [f (begin (write-module! "ledger" "#!tuna\n(define (g) 1)\n") (load-named '(ledger)) (eval 'ledger:g (environment '(ledger))))])
    (define (a1 next) (next))
    (define (a2 next) (next))
    (call-as-owner o (lambda () (advice-add! f a1) (on-unload void) (override-set! f (lambda () 2)) (advice-add! f a2)))
    (check-equal? '(advice override unload-action advice) (map car (owner-changes o)))
    (check-equal? '(advice override advice define) (map cadr (definition-changes f)))
    (call-as-owner o (lambda () (advice-add! f a1)))
    (check-equal? 4 (length (owner-changes o)))
    (unload-owner! o)
    (check-equal? '(define) (map cadr (definition-changes f)))
    (check-equal? 1 (f))))

(test "changes made on another thread raise and change nothing"
  (let ([f (eval 'ledger:g (environment '(ledger)))])
    (check-equal? "only the main thread changes owners and modules"
      (let ([o #f])
        (join-task (as-test-owner (lambda () (fork-task (lambda (restore) (set! o (guard (e [#t (condition-message e)]) (advice-add! f (lambda (next) (next))))))))))
        o))
    (check-equal? '(define) (map cadr (definition-changes f)))
    (check-equal? f (let ([g #f]) (join-task (fork-task (lambda (restore) (set! g (eval 'ledger:g (environment '(ledger))))))) g))))

(test "a signal handler is taken back with its owner, and the one it replaced gets the signal again"
  (let ([log '()] [first (make-owner '(signals first))] [second (make-owner '(signals second))])
    (call-as-owner first (lambda () (tuna-register-signal-handler 10 (lambda (sig) (set! log (cons 'first log))))))
    (call-as-owner second (lambda () (tuna-register-signal-handler 10 (lambda (sig) (set! log (cons 'second log))))))
    (send-signal! 10)
    (test-runner:wait-until (lambda () (equal? '(second) log)))
    (unload-owner! second)
    (send-signal! 10)
    (test-runner:wait-until (lambda () (equal? '(first second) log)))
    (unload-owner! first)
    (send-signal! 10)
    (pause-ms 100)
    (check-equal? '(first second) log)))

(test "a reload that succeeds unloads a module whose raise its body caught"
  (write-module! "catcher" "#!tuna\n(define caught 'nothing)\n")
  (load-named '(catcher))
  (next-file-tick)
  (write-module! "kaboom" "#!tuna\n(define (x) 1)\n(car '())\n")
  (write-module! "catcher" "#!tuna\n(define caught (guard (c [#t 'caught]) (invoke-library '(kaboom))))\n")
  (reload-modules! '((catcher)))
  (check-equal? 'caught (eval 'catcher:caught (environment '(catcher))))
  (test-runner:wait-until (lambda () (not (owner-of '(kaboom)))))
  (check (owner-live? (owner-of '(catcher))))
  (write-module! "after-catcher" "#!tuna\n(define (f) 1)\n")
  (check (owner? (load-named '(after-catcher)))))

(test "a body that raises when Chez invokes it, outside a load, is dropped"
  (write-module! "evalboom" "#!tuna\n(define (x) 1)\n(car '())\n")
  (check-raises serious-condition? (eval '(evalboom:x) (environment '(evalboom))))
  (test-runner:wait-until (lambda () (not (owner-of '(evalboom)))))
  (write-module! "localboom" "#!tuna\n(define (x) 1)\n(car '())\n")
  (check-raises serious-condition? (eval '(let () (import (localboom)) (localboom:x)) (interaction-environment)))
  (test-runner:wait-until (lambda () (not (owner-of '(localboom))))))

(test "a jump back into an owner's code runs as the owner, and raises &unloaded once its unload has begun"
  (let ([o (make-owner '(reentered))] [before (current-owner)] [k #f] [log '()])
    (guard (c [(unloaded? c) (set! log (cons (list 'unloaded (owner-name (unloaded-owner c))) log))])
      (let ([seen (call-as-owner o (lambda () (call/cc (lambda (c) (set! k c))) (current-owner)))])
        (set! log (cons seen log))
        (case (length log)
          [(1) (k #f)]
          [(2) (unload-owner! o) (k #f)])))
    (check-equal? (list o o '(unloaded (reentered))) (reverse log))
    (check-equal? before (current-owner))))

(test "loading, reloading and unloading from a thread's task run on the main thread"
  (write-module! "threaded" "#!tuna\n(define (f) 1)\n")
  (let ([results #f])
    (join-task
      (as-test-owner
        (lambda ()
          (fork-task
            (lambda (restore)
              (let ([first (load-module! '(threaded))])
                (reload-modules! '((threaded)))
                (let ([second (module-owner '(threaded))])
                  (unload-owner! second)
                  (set! results (list (owner? first) (eq? first second) (owner-live? second) (module-owner '(threaded)))))))))))
    (check-equal? '(#t #f #f #f) results)))

(test "a removal of advice holds the advice weakly"
  (write-module! "weakly" "#!tuna\n(define (g) 1)\n")
  (load-named '(weakly))
  (let ([g (eval 'weakly:g (environment '(weakly)))] [o (make-owner '(remover))] [probe (weak-cons #f #f)])
    (call-as-owner o
      (lambda ()
        (let ([advice (let ([n (random 10)]) (lambda (next) (+ n (next))))])
          (set-car! probe advice)
          (advice-remove! g advice))))
    (collect (collect-maximum-generation))
    (check (bwp-object? (car probe)))
    (check-equal? 1 (g))
    (unload-owner! o)))

(test "other threads look owners up while the main thread loads modules"
  (write-module! "looked-up" "#!tuna\n(define (f) 1)\n")
  (let ([o (load-named '(looked-up))] [stop? (box #f)] [wrong (box 0)])
    (let ([readers (map (lambda (i)
                          (as-test-owner
                            (lambda ()
                              (fork-task
                                (lambda (restore)
                                  (let loop ()
                                    (unless (unbox stop?)
                                      (unless (eq? o (module-owner '(looked-up))) (bump! wrong))
                                      (loop))))))))
                        (iota 3))])
      (do ([i 0 (+ i 1)]) ((= i 20))
        (let ([name (format "many~a" i)])
          (write-module! name "#!tuna\n(define (f) 1)\n")
          (load-named (list (string->symbol name)))))
      (set-box! stop? #t)
      (for-each join-task readers)
      (check-equal? 0 (unbox wrong))
      (let ([seen #f])
        (join-task (as-test-owner (lambda () (fork-task (lambda (restore) (set! seen (module-owner '(many19))))))))
        (check-equal? (owner-of '(many19)) seen)))))

(test "task-frames gives a paused thread task's frames as data"
  (let ([t (as-test-owner (lambda () (fork-task (lambda (restore) (suspend (lambda (resume) (void)))))))])
    (test-runner:wait-until (lambda () (eq? 'paused (task-state t))))
    (let ([frames (task-frames t)])
      (check (pair? frames))
      (check (for-all pair? frames)))
    (stop-task t)
    (join-task t)))

(test "a restore called after its mask was left by a raise raises"
  (let ([kept #f])
    (guard (c [(error? c) (void)])
      (call-with-cancellation-masked
        (lambda (restore)
          (set! kept restore)
          (error 'mask "leaving"))))
    (check-raises assertion-violation? (kept void))))

(test "a cancel that lands in report's advice ends the task cancelled"
  (let* ([in-report (box #f)]
         [slow (lambda (next c) (set-box! in-report #t) (spin-for 100000000))]
         [t (spawn-task (lambda (restore) (call-reporting (lambda () (error 'reported "boom"))) 'went-on))])
    (as-test-owner (lambda () (advice-add! report slow)))
    (fork-task (lambda (restore) (when (wait-on-thread (lambda () (unbox in-report)) t) (cancel-task t 'mine))))
    (check-equal? '(cancelled mine) (ended t))
    (as-test-owner (lambda () (advice-remove! report slow)))))

(test "while a stop unwinds a task, each winder runs as the owner of its own code"
  (let* ([o (make-owner '(stopped inside))] [seen #f] [before (current-owner)]
         [t (spawn-task
              (lambda (restore)
                (dynamic-wind
                  void
                  (lambda () (call-as-owner o spin))
                  (lambda () (set! seen (current-owner))))))])
    (fork-task (lambda (restore) (sleep-ms 5) (stop-task t)))
    (join-task t)
    (check-equal? before seen)
    (unload-owner! o)))

(test "a module's % procedures are not exported, so no import reaches them, and the top level binds them"
  (write-module! "hidden" "#!tuna\n(define (%helper) 'helped)\n(define (shown) (%helper))\n")
  (write-module! "peeker" "#!tuna\n(import (hidden))\n(define (peek) (hidden:%helper))\n")
  (load-named '(hidden))
  (check (memq 'hidden:shown (library-exports '(hidden))))
  (check (not (memq 'hidden:%helper (library-exports '(hidden)))))
  (check-raises syntax-violation? (load-named '(peeker)))
  (check-equal? 'helped (eval '(hidden:%helper) (interaction-environment))))

(test "a first stop that lands in with-mutex's winders still releases the mutex"
  (write-module! "locker"
    (string-append
      "#!tuna\n"
      "(define (hammer m) (fork-task (lambda (restore) (let loop () (with-mutex m (void)) (loop)))))\n"
      "(define (escape m) (fork-task (lambda (restore) (let loop () (call/cc (lambda (k) (with-mutex m (k #f)))) (loop)))))\n"))
  (load-named '(locker))
  (let ([env (environment '(locker))])
    (for-each
      (lambda (start)
        (let ([held 0])
          (do ([trial 0 (+ trial 1)]) ((= trial 200))
            (let* ([m (make-mutex)] [t (as-test-owner (lambda () (start m)))])
              (sleep-ms (+ 1 (mod trial 3)))
              (stop-task t)
              (join-task t)
              (if (mutex-acquire m #f) (mutex-release m) (set! held (+ held 1)))))
          (check-equal? 0 held)))
      (list (eval 'locker:hammer env) (eval 'locker:escape env)))))

(test "a reload loads modules that import none of each other in the order they first loaded"
  (write-module! "manager" "#!tuna\n(define %started (box #f))\n(define (start!) (set-box! %started #t))\n(define (need) (unless (unbox %started) (error 'need \"not started\")) 'started)\n")
  (write-module! "starter" "#!tuna\n(import (manager))\n(manager:start!)\n")
  (write-module! "needer" "#!tuna\n(import (manager))\n(define seen (manager:need))\n")
  (load-named '(starter))
  (load-named '(needer))
  (reload-modules! '((manager)))
  (check-equal? 'started (eval 'needer:seen (environment '(needer)))))

(test "a batch ends before a resume queued while its task paused"
  (let* ([log '()]
         [count (lambda (next) (set! log (cons 'ended log)) (next))])
    (as-test-owner (lambda () (advice-add! batch-ended count)))
    (join-task
      (spawn-task
        (lambda (restore)
          (do ([i 0 (+ i 1)]) ((= i 6))
            (set! log (cons 'step log))
            (dynamic-wind
              void
              (lambda ()
                (suspend
                  (lambda (resume)
                    (fork-task (lambda (restore) (sleep-ms (if (odd? i) 1 30)) (resume void))))))
              (lambda () (spin-for 20000000)))))))
    (as-test-owner (lambda () (advice-remove! batch-ended count)))
    (let ([log (reverse log)])
      (check-equal? 6 (length (filter (lambda (x) (eq? x 'step)) log)))
      (check (not (exists (lambda (a b) (and (eq? a 'step) (eq? b 'step)))
                          (list-head log (- (length log) 1)) (cdr log)))))))

(test "a cancel that lands in spawn-task or fork-task leaves no task that never runs"
  (let* ([o (make-owner '(spawner))]
         [made (lambda (spawn)
                 (call-as-owner o
                   (lambda ()
                     (spawn-task
                       (lambda (restore)
                         (let ([until (+ (real-time) 100)])
                           (let again ()
                             (guard (c [(cancelled? c) (again)])
                               (let loop ()
                                 (when (< (real-time) until)
                                   (spawn (lambda (restore) (void)))
                                   (loop)))))))))))])
    (for-each
      (lambda (spawn)
        (let* ([t (made spawn)]
               [asker (fork-task (lambda (restore) (let loop () (unless (done? t) (cancel-task t) (loop)))))])
          (join-task t)
          (join-task asker)
          (test-runner:wait-until (lambda () (null? (filter (lambda (t) (eq? (task-owner t) o)) (live-tasks)))))))
      (list spawn-task fork-task))
    (unload-owner! o)))

(test "a stop lets the winder it lands in finish, and a further stop skips it"
  (write-module! "winders"
    (string-append
      "#!tuna\n"
      "(define (slow-in log) (fork-task (lambda (restore) (dynamic-wind (lambda () (let loop ([i 0]) (when (< i 50000000) (loop (+ i 1)))) (set-box! log '(in))) (lambda () (let loop () (loop))) (lambda () (set-box! log (cons 'out (unbox log))))))))\n"
      "(define (stuck log) (fork-task (lambda (restore) (dynamic-wind (lambda () (set-box! log 'in) (let loop () (loop))) void void))))\n"))
  (load-named '(winders))
  (let ([env (environment '(winders))] [log (box #f)])
    (let ([t (as-test-owner (lambda () ((eval 'winders:slow-in env) log)))])
      (sleep-ms 5)
      (stop-task t)
      (check-equal? '(stopped #f) (ended t))
      (check-equal? '(out in) (unbox log)))
    (let ([t (as-test-owner (lambda () ((eval 'winders:stuck env) log)))])
      (test-runner:wait-until (lambda () (eq? 'in (unbox log))))
      (stop-task t)
      (sleep-ms 20)
      (check-equal? 'running (task-state t))
      (stop-task t)
      (check-equal? '(stopped #f) (ended t)))))

(test "taking back one change from the middle keeps the others and their order"
  (write-module! "middle" "#!tuna\n(define (g) '())\n")
  (load-named '(middle))
  (let ([g (eval 'middle:g (environment '(middle)))] [o (make-owner '(middle owner))])
    (define (layer name) (lambda (next) (cons name (next))))
    (let ([a (layer 'a)] [b (layer 'b)] [c (layer 'c)])
      (call-as-owner o (lambda () (advice-add! g a) (advice-add! g b) (advice-add! g c)))
      (check-equal? '(c b a) (g))
      (call-as-owner o (lambda () (advice-remove! g b)))
      (check-equal? '(c a) (g))
      (check-equal? (list c a) (map caddr (filter (lambda (change) (eq? 'advice (cadr change))) (definition-changes g))))
      (unload-owner! o)
      (check-equal? '() (g)))))

(test "an owner's second override replaces its first"
  (write-module! "overridden" "#!tuna\n(define (g) 'defined)\n")
  (load-named '(overridden))
  (let ([g (eval 'overridden:g (environment '(overridden)))] [o (make-owner '(overrider))])
    (call-as-owner o (lambda () (override-set! g (lambda () 'first)) (override-set! g (lambda () 'second))))
    (check-equal? 'second (g))
    (check-equal? '(override define) (map cadr (definition-changes g)))
    (call-as-owner o (lambda () (override-remove! g)))
    (check-equal? 'defined (g))
    (unload-owner! o)
    (check-equal? 'defined (g))))

(test "advice keeps rank, then each owner's order, through additions, removals and unloads"
  (write-module! "ordered" "#!tuna\n(define (g) '())\n")
  (load-named '(ordered))
  (let* ([g (eval 'ordered:g (environment '(ordered)))] [low (make-owner '(order low))] [high (make-owner '(order high))])
    (define (layer name) (lambda (next) (cons name (next))))
    (let ([a1 (layer 'a1)] [a2 (layer 'a2)] [a3 (layer 'a3)] [b1 (layer 'b1)] [b2 (layer 'b2)])
      (call-as-owner high (lambda () (advice-add! g b1)))
      (call-as-owner low (lambda () (advice-add! g a1) (advice-add! g a2)))
      (check-equal? '(b1 a2 a1) (g))
      (call-as-owner low (lambda () (advice-remove! g a1) (advice-add! g a3)))
      (call-as-owner high (lambda () (advice-add! g b2)))
      (check-equal? '(b2 b1 a3 a2) (g))
      (unload-owner! high)
      (check-equal? '(a3 a2) (g))
      (call-as-owner low (lambda () (advice-add! g a1)))
      (check-equal? '(a1 a3 a2) (g))
      (unload-owner! low)
      (check-equal? '() (g)))))

(test "directory-list raises an i/o error for a folder that is not there, as the module lookup relies on"
  (check-equal? 'i/o (guard (c [(i/o-error? c) 'i/o]) (directory-list (string-append (getenv "HOME") "/not-there")))))

(test "a call on another thread that waits in advice across its module's reload runs the new definition"
  (write-module! "versioned" "#!tuna\n(define (g) 'old)\n")
  (load-named '(versioned))
  (let* ([g (eval 'versioned:g (environment '(versioned)))] [o (make-owner '(waiting adviser))] [inside (box #f)] [go (box #f)])
    (call-as-owner o
      (lambda ()
        (advice-add! g (lambda (next) (set-box! inside #t) (let wait () (unless (unbox go) (sleep-ms 1) (wait))) (next)))))
    (let ([t (as-test-owner (lambda () (fork-task (lambda (restore) (g)))))])
      (test-runner:wait-until (lambda () (unbox inside)))
      (next-file-tick)
      (write-module! "versioned" "#!tuna\n(define (g) 'new)\n")
      (reload-modules! '((versioned)))
      (set-box! go #t)
      (check-equal? '(returned (new)) (ended t)))
    (unload-owner! o)))

(test "a thread's raise is reported in a task of the owner the thread acted for"
  (let* ([o (make-owner '(raising thread))] [reporter #f]
         [quiet (lambda (next c) (set! reporter (task-owner (current-task))))])
    (as-test-owner (lambda () (advice-add! report quiet)))
    (ended (call-as-owner o (lambda () (fork-task (lambda (restore) (error 'thread "from a thread"))))))
    (test-runner:wait-until (lambda () reporter))
    (check-equal? o reporter)
    (as-test-owner (lambda () (advice-remove! report quiet)))
    (unload-owner! o)))

(test "a library is first looked up on the main thread, and a thread's look-up raises and is reported"
  (write-module! "plainlib" "(library (plainlib) (export x) (import (chezscheme)) (define x 'plain))\n")
  (let* ([reported #f]
         [keep (lambda (next c) (set! reported c))]
         [t (as-test-owner
              (lambda ()
                (advice-add! report keep)
                (fork-task (lambda (restore) (eval 'x (environment '(plainlib)))))))])
    (let ([e (ended t)])
      (check-equal? 'raised (car e))
      (check-equal? "a library is first loaded on the main thread" (condition-message (cadr e)))
      (test-runner:wait-until (lambda () reported))
      (check-equal? (cadr e) reported))
    (as-test-owner (lambda () (advice-remove! report keep))))
  (check-equal? 'plain (eval 'x (environment '(plainlib))))
  (let ([t (as-test-owner (lambda () (fork-task (lambda (restore) (eval 'x (environment '(plainlib)))))))])
    (check-equal? '(returned (plain)) (ended t))))

(test "a cancel that arrives while a task pauses lands at the pause, in the task's own handler"
  (let* ([log '()]
         [t (spawn-task
              (lambda (restore)
                (guard (c [(cancelled? c) (set! log (cons 'caught log)) (cancelled-reason c)])
                  (dynamic-wind
                    void
                    (lambda () (suspend (lambda (resume) (void))))
                    (lambda () (set! log (cons 'out log)) (spin-for 20000000) (set! log (cons 'out-done log)))))))])
    (fork-task (lambda (restore) (when (wait-on-thread (lambda () (memq 'out log)) t) (cancel-task t 'mine))))
    (check-equal? '(returned (mine)) (ended t))
    (check-equal? '(out out-done out out-done caught) (reverse log))))

(test "a cancel that lands while a cancel is reported ends the task cancelled and escapes nowhere"
  (let* ([in-report (box #f)]
         [slow (lambda (next c) (set-box! in-report #t) (spin-for 100000000))]
         [t (spawn-task (lambda (restore) (spin)))])
    (as-test-owner (lambda () (advice-add! report slow)))
    (cancel-task t 'first)
    (fork-task (lambda (restore) (when (wait-on-thread (lambda () (unbox in-report)) t) (cancel-task t 'second))))
    (check-equal? 'cancelled (car (ended t)))
    (as-test-owner (lambda () (advice-remove! report slow)))
    (check-equal? '(returned (went-on)) (ended (spawn-task (lambda (restore) 'went-on))))))

(test "a task paused in an owner's advice goes on as that owner when resumed"
  (write-module! "pausing" "#!tuna\n(define (g) (current-owner))\n")
  (load-named '(pausing))
  (let ([g (eval 'pausing:g (environment '(pausing)))] [o (make-owner '(pausing adviser))] [caller (make-owner '(pausing caller))] [seen #f])
    (call-as-owner o
      (lambda ()
        (advice-add! g (lambda (next)
                         (suspend (lambda (resume) (fork-task (lambda (restore) (sleep-ms 5) (resume void)))))
                         (set! seen (current-owner))
                         (next)))))
    (check-equal? caller (call-as-owner caller g))
    (check-equal? o seen)
    (unload-owner! o)
    (unload-owner! caller)))

(test "task-frames gives a paused task's frames as data"
  (let ([t (spawn-task (lambda (restore) (suspend (lambda (resume) (void)))))])
    (pause-ms 1)
    (let ([frames (task-frames t)])
      (check (list? frames))
      (check (for-all pair? frames)))
    (stop-task t)
    (join-task t)
    (check-equal? '() (task-frames t))))
