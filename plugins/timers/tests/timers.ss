(import (tuna) (test) (test-runner) (timers) (rename (only (chezscheme) sleep fork-thread thread-join) (sleep chez:sleep) (fork-thread chez:fork-thread) (thread-join chez:thread-join)))

(define (sleep-ms ms)
  (chez:sleep (make-time 'time-duration (* (mod ms 1000) 1000000) (quotient ms 1000))))

(define (seconds-now)
  (let ([t (current-time 'time-monotonic)])
    (+ (time-second t) (/ (time-nanosecond t) 1e9))))

;; Chez's sleep, not timers:sleep, so the main thread stays busy, as a long
;; computation would keep it.
(define (block seconds)
  (chez:sleep (make-time 'time-duration (exact (round (* seconds 1e9))) 0)))

(define (wait-for-done receive-done)
  (let ([called (box #f)])
    (receive-done (lambda () (set-box! called #t)))
    (test-runner:wait-until (lambda () (unbox called)))))

(define (on-thread thunk)
  (let ([result #f])
    (join-task (fork-task (lambda (restore) (set! result (guard (c [#t (condition-message c)]) (thunk))))))
    result))

;; A due time is known only to lie between two clock readings, since the
;; thread can be descheduled between a reading and the call that sets the
;; time, so it is kept as the earliest and latest it can be. Runs are in
;; order when each could have been due no later than the next.
(define-record-type due
  (fields delay earliest (mutable latest))
  (protocol
    (lambda (new)
      (lambda (delay before)
        (new delay (+ before delay) +inf.0)))))

(define (due-set-after! d after)
  (due-latest-set! d (+ after (due-delay d))))

(define (in-due-order? dues)
  (or (null? dues) (null? (cdr dues))
      (and (<= (due-earliest (car dues)) (due-latest (cadr dues))) (in-due-order? (cdr dues)))))

(test "a timer runs its procedure once, in a task of its own, as the owner that made it, and then ends"
  (let* ([o (make-owner '(timer maker))] [seen #f] [made #f])
    (wait-for-done
      (lambda (done)
        (set! made (call-as-owner o (lambda () (timers:run-after 0.01 (lambda () (set! seen (list (current-owner) (task? (current-task)))) (done))))))
        (check (timers:timer? made))
        (check-equal? (list made) (timers:live))))
    (check-equal? (list o #t) seen)
    (test-runner:wait-until (lambda () (null? (timers:live))))
    (unload-owner! o)))

(test "timers:procedure gives the procedure a timer runs"
  (let* ([ring (lambda () 'ring)] [t (timers:run-after 60 ring)])
    (check-equal? ring (timers:procedure t))
    (check (not (timers:timer? ring)))
    (timers:cancel! t)))

(test "a repeating timer runs every repeat seconds until it is cancelled"
  (let ([times '()] [t #f] [start (seconds-now)])
    (wait-for-done
      (lambda (done)
        (set! t (timers:run-after 0.05 (lambda () (set! times (cons (seconds-now) times)) (when (= (length times) 3) (done))) 0.05))))
    (timers:cancel! t)
    (let ([runs (length times)])
      (timers:sleep 0.15)
      (check-equal? runs (length times)))
    (check (>= (car times) (+ start 0.15)))
    (check-equal? '() (timers:live))))

(test "a timer cancelled before it is due never runs"
  (let ([ran #f])
    (timers:cancel! (timers:run-after 0.05 (lambda () (set! ran #t))))
    (timers:sleep 0.1)
    (check-equal? #f ran)))

(test "a cancel while the procedure runs lets it run to its end"
  (let ([log '()] [t #f])
    (wait-for-done
      (lambda (done)
        (set! t (timers:run-after 0
                  (lambda ()
                    (set! log (cons 'started log))
                    (timers:cancel! t)
                    (timers:sleep 0.01)
                    (set! log (cons 'ended log))
                    (done))))))
    (check-equal? '(started ended) (reverse log))))

(test "a timer's raise is reported, and the next timer runs"
  (let ([ran #f])
    (check-equal? 1
      (length
        (test-runner:reports-during
          (lambda ()
            (wait-for-done
              (lambda (done)
                (timers:run-after 0.01 (lambda () (error 'timer "failed")))
                (timers:run-after 0.05 (lambda () (set! ran #t) (done)))))))))
    (check ran)))

(test "timers:sleep pauses only the current task"
  (let ([napping (spawn-task (lambda (restore) (timers:sleep 0.3) 'rested))])
    (timers:sleep 0.05)
    (check (not (eq? (task-state napping) 'done)))
    (check-equal? 'rested (test-runner:join napping))))

(test "a task that sleeps can raise when it wakes, and a cancel reaches it while it sleeps"
  (let ([failing (spawn-task (lambda (restore) (timers:sleep 0.05) (error 'nap "woke badly")))])
    (check-equal? 1 (length (test-runner:reports-during (lambda () (check-raises error? (test-runner:join failing)))))))
  (let ([waiting (spawn-task (lambda (restore) (timers:sleep 100)))])
    (test-runner:wait-until (lambda () (eq? (task-state waiting) 'paused)))
    (cancel-task waiting 'stop)
    (check-equal? 'stop (guard (c [(cancelled? c) (cancelled-reason c)]) (test-runner:join waiting)))))

(test "only a task sleeps, for a number of seconds that is not negative"
  (let ([r #f])
    (chez:thread-join (chez:fork-thread (lambda () (set! r (guard (c [#t (condition-message c)]) (timers:sleep 1))))))
    (check-equal? "not in a task" r))
  (check-raises assertion-violation? (timers:sleep -1))
  (timers:sleep 0))

(test "an idle timer runs once in each idle period, after Tuna has been idle for its seconds"
  (let* ([runs 0] [next #f]
         [idler (timers:run-when-idle 0.05 (lambda () (set! runs (+ runs 1)) (when next (next))))])
    (timers:set-idle! #f)
    (check-equal? #f (timers:idle-seconds))
    (timers:sleep 0.1)
    (check-equal? 0 runs)
    (wait-for-done (lambda (done) (set! next done) (timers:set-idle! #t)))
    (check-equal? 1 runs)
    (check (>= (timers:idle-seconds) 0.05))
    (timers:set-idle! #t)
    (timers:sleep 0.1)
    (check-equal? 1 runs)
    (timers:set-idle! #f)
    (wait-for-done (lambda (done) (set! next done) (timers:set-idle! #t)))
    (check-equal? 2 runs)
    (on-thread (lambda () (timers:set-idle! #f)))
    (check-equal? #f (timers:idle-seconds))
    (timers:cancel! idler)
    (timers:set-idle! #t)
    (timers:sleep 0.1)
    (check-equal? 2 runs)
    (timers:set-idle! #f)
    (check-raises assertion-violation? (timers:set-idle! 'yes))))

(import (timers-test ticker))

(test "unloading a module stops its timers, paused ones past their handlers, and reloading starts them afresh"
  (test-runner:wait-until (lambda () (> (timers-test/ticker:count) 1)))
  (let ([first (timers:live)])
    (check-equal? 1 (length first))
    (reload-modules! '((timers-test ticker)))
    (check-equal? 1 (length (timers:live)))
    (check (not (eq? (car first) (car (timers:live))))))
  (let ([quit #f] [inside (box #f)])
    (call-as-owner (module-owner '(timers-test ticker))
      (lambda ()
        (timers:run-after 0
          (lambda () (guard (c [(cancelled? c) (set! quit #t)]) (set-box! inside #t) (timers:sleep 3600))))))
    (test-runner:wait-until (lambda () (unbox inside)))
    (unload-owner! (module-owner '(timers-test ticker)))
    (check-equal? '() (timers:live))
    (check-equal? #f quit)))

(test "arguments are checked, and a timer is made and cancelled on any thread"
  (check-raises assertion-violation? (timers:run-after -1 void))
  (check-raises assertion-violation? (timers:run-after 1 void 0))
  (check-raises assertion-violation? (timers:run-after 1 'ring))
  (check-raises assertion-violation? (timers:cancel! void))
  (let ([t (on-thread (lambda () (timers:run-after 60 void)))])
    (check (timers:timer? t))
    (on-thread (lambda () (timers:cancel! t)))
    (test-runner:wait-until (lambda () (null? (timers:live))))))

(test "timers run in the order of their times, and none early"
  (let ([ran '()] [n 80])
    (wait-for-done
      (lambda (done)
        (do ([i 0 (+ i 1)]) ((= i n))
          (let ([due (make-due (/ (random 150) 1000.) (seconds-now))])
            (timers:run-after (due-delay due)
              (lambda ()
                (set! ran (cons (cons due (seconds-now)) ran))
                (when (= (length ran) n) (done))))
            (due-set-after! due (seconds-now))))))
    (let ([ran (reverse ran)])
      (check (in-due-order? (map car ran)))
      (check (for-all (lambda (r) (>= (cdr r) (due-earliest (car r)))) ran)))
    (check-equal? '() (timers:live))))

(test "a timer cancelled after its run was posted never runs"
  (let ([ran 0])
    (do ([i 0 (+ i 1)]) ((= i 300))
      (let ([t (timers:run-after 0 (lambda () (set! ran (+ ran 1))))])
        (block (/ (random 1000) 1e6))
        (timers:cancel! t)))
    (timers:sleep 0.05)
    (check-equal? 0 ran)
    (check-equal? '() (timers:live))))

;; The block ends half a period before the next due time, so the one
;; run that waited is the only one when the task goes on.
(test "a repeating timer that falls behind runs once"
  (let* ([runs 0] [t (timers:run-after 0.1 (lambda () (set! runs (+ runs 1))) 0.1)])
    (block 0.45)
    (timers:sleep 0.01)
    (check-equal? 1 runs)
    (timers:sleep 0.1)
    (check-equal? 2 runs)
    (timers:cancel! t)))

;; The tasks start one at a time and every one starts before any wakes,
;; so a sleep's time is set between its task's start and the next's.
(test "sleeping tasks wake in the order of their times, and none early"
  (let* ([woke '()]
         [previous #f]
         [tasks (map (lambda (i)
                       (let ([seconds (/ (random 100) 1000.)])
                         (spawn-task
                           (lambda (restore)
                             (let* ([now (seconds-now)] [due (make-due seconds now)])
                               (when previous (due-set-after! previous now))
                               (set! previous due)
                               (timers:sleep seconds)
                               (set! woke (cons (cons due (seconds-now)) woke)))))))
                     (iota 100))])
    (for-each join-task tasks)
    (let ([woke (reverse woke)])
      (check-equal? 100 (length woke))
      (check (in-due-order? (map car woke)))
      (check (for-all (lambda (w) (>= (cdr w) (due-earliest (car w)))) woke)))))

(test "set-idle! from many threads while an idle timer runs"
  (let* ([runs 0] [t (timers:run-when-idle 0 (lambda () (set! runs (+ runs 1))))])
    (for-each join-task
      (map (lambda (i)
             (fork-task
               (lambda (restore)
                 (do ([n 0 (+ n 1)]) ((= n 2000))
                   (timers:set-idle! (odd? n))
                   (timers:idle-seconds)))))
           (iota 4)))
    (timers:set-idle! #f)
    (check-equal? #f (timers:idle-seconds))
    (timers:sleep 0.02)
    (let ([before runs])
      (timers:set-idle! #t)
      (timers:sleep 0.05)
      (check-equal? (+ before 1) runs))
    (timers:set-idle! #f)
    (timers:cancel! t)))

(test "a cancel never leaves a timer half added or half cancelled"
  (let ([cancelled 0])
    (do ([i 0 (+ i 1)]) ((= i 300))
      (let ([t (spawn-task
                 (lambda (restore)
                   (let loop ()
                     (let ([once (timers:run-after 0 void)] [repeating (timers:run-after 0 void 1)])
                       (timers:cancel! once)
                       (timers:cancel! repeating))
                     (loop))))])
        (fork-task (lambda (restore) (sleep-ms (random 3)) (cancel-task t)))
        (let-values ([(how detail) (join-task t)])
          (when (eq? how 'cancelled) (set! cancelled (+ cancelled 1))))))
    (check (> cancelled 250))
    (for-each timers:cancel! (timers:live))
    (timers:sleep 0.05)
    (check-equal? '() (timers:live))))
