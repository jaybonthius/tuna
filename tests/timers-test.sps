(import (chezscheme) (tuna-test) (tuna core changes) (except (tuna core main-thread) exit) (tuna timers))

(define (seconds-now)
  (let ([t (current-time 'time-monotonic)])
    (+ (time-second t) (/ (time-nanosecond t) 1e9))))

(define (block seconds)
  (sleep (make-time 'time-duration (exact (round (* seconds 1e9))) 0)))

(define (wait-until-called receive-done)
  (suspend (lambda (resume) (receive-done (lambda () (resume void))))))

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

(define (timer-changes)
  (filter (lambda (change) (eq? (car change) 'timer)) (module-changes '(repl))))

(define (tests)
  (test "timers run in the order of their times, and none early"
    (let ([ran '()] [n 80])
      (wait-until-called
        (lambda (done)
          (do ([i 0 (+ i 1)]) ((= i n))
            (let ([due (make-due (/ (random 150) 1000.) (seconds-now))])
              (run-with-timer (due-delay due)
                (lambda ()
                  (set! ran (cons (cons due (seconds-now)) ran))
                  (when (= (length ran) n) (done))))
              (due-set-after! due (seconds-now))))))
      (let ([ran (reverse ran)])
        (check (in-due-order? (map car ran)))
        (check (for-all (lambda (r) (>= (cdr r) (due-earliest (car r)))) ran)))
      (check-equal? '() (timers))
      (check-equal? '() (timer-changes))))

  (test "a timer cancelled after its run was posted never runs"
    (let ([ran 0])
      (do ([i 0 (+ i 1)]) ((= i 300))
        (let ([t (run-with-timer 0 (lambda () (set! ran (+ ran 1))))])
          (block (/ (random 1000) 1e6))
          (cancel-timer! t)))
      (sleep-for 0.05)
      (check-equal? 0 ran)
      (check-equal? '() (timers))
      (check-equal? '() (timer-changes))))

  ;; The block ends half a period before the next due time, so the one
  ;; run that waited is the only one when the task goes on.
  (test "a repeating timer that falls behind runs once"
    (let* ([runs 0] [t (run-with-timer 0.1 (lambda () (set! runs (+ runs 1))) 0.1)])
      (block 0.45)
      (sleep-for 0)
      (check-equal? 1 runs)
      (sleep-for 0.1)
      (check-equal? 2 runs)
      (cancel-timer! t)))

  ;; The tasks start one at a time and every one starts before any wakes,
  ;; so a sleep's time is set between its task's start and the next's.
  (test "sleeping tasks wake in the order of their times, and none early"
    (let* ([woke '()]
           [previous #f]
           [tasks (map (lambda (i)
                         (let ([seconds (/ (random 100) 1000.)])
                           (spawn-task
                             (lambda ()
                               (let* ([now (seconds-now)] [due (make-due seconds now)])
                                 (when previous (due-set-after! previous now))
                                 (set! previous due)
                                 (sleep-for seconds)
                                 (set! woke (cons (cons due (seconds-now)) woke)))))))
                       (iota 100))])
      (for-each join-task tasks)
      (let ([woke (reverse woke)])
        (check-equal? 100 (length woke))
        (check (in-due-order? (map car woke)))
        (check (for-all (lambda (w) (>= (cdr w) (due-earliest (car w)))) woke)))))

  (test "set-idle! from many threads while an idle timer runs"
    (let* ([runs 0] [t (run-with-idle-timer 0 (lambda () (set! runs (+ runs 1))))])
      (for-each thread-join
        (map (lambda (i)
               (fork-thread
                 (lambda ()
                   (do ([n 0 (+ n 1)]) ((= n 2000))
                     (set-idle! (odd? n))
                     (idle-seconds)))))
             (iota 4)))
      (set-idle! #f)
      (check-equal? #f (idle-seconds))
      (sleep-for 0.02)
      (let ([before runs])
        (set-idle! #t)
        (sleep-for 0.05)
        (check-equal? (+ before 1) runs))
      (set-idle! #f)
      (cancel-timer! t)))

  (test "a quit never leaves a timer half added or half cancelled"
    (let ([changing? #f] [quits-while-changing 0])
      (define (burn n) (if (fx= n 0) 0 (fx+ 1 (burn (fx- n 1)))))
      (do ([i 0 (+ i 1)]) ((= i 3000))
        (guard (c [(quit-condition? c)
                   (when changing? (set! quits-while-changing (+ quits-while-changing 1)))])
          (burn (random 1500))
          (request-quit!)
          (set! changing? #t)
          (do ([j 0 (fx+ j 1)]) ((fx= j 30))
            (let ([once (run-with-timer 0 void)] [repeating (run-with-timer 0 void 1)])
              (cancel-timer! once)
              (cancel-timer! repeating)))
          (set! changing? #f)
          (let loop () (loop))))
      (check (> quits-while-changing 1000))
      (let ([live (timers)] [changed (map cadr (timer-changes))])
        (check-equal? (length live) (length changed))
        (check (for-all (lambda (t) (memq t changed)) live)))
      (for-each cancel-timer! (timers))
      (sleep-for 0.05)
      (check-equal? '() (timers))
      (check-equal? '() (timer-changes)))))

(post! (lambda ()
         (tests)
         (test-exit)))
(run-main-loop)
