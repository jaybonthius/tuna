(import (chezscheme) (tuna-test) (tuna core changes) (except (tuna core main-thread) exit) (tuna timers))

(define (seconds-now)
  (let ([t (current-time 'time-monotonic)])
    (+ (time-second t) (/ (time-nanosecond t) 1e9))))

(define (block seconds)
  (sleep (make-time 'time-duration (exact (round (* seconds 1e9))) 0)))

(define (wait-until-called receive-done)
  (suspend (lambda (resume) (receive-done (lambda () (resume void))))))

(define (non-decreasing? xs)
  (or (null? xs) (null? (cdr xs)) (and (<= (car xs) (cadr xs)) (non-decreasing? (cdr xs)))))

(define (timer-changes)
  (filter (lambda (change) (eq? (car change) 'timer)) (module-changes '(repl))))

(define (tests)
  (test "timers run in the order of their times, and none early"
    (let ([ran '()] [n 80] [start (seconds-now)])
      (wait-until-called
        (lambda (done)
          (do ([i 0 (+ i 1)]) ((= i n))
            (let ([delay (/ (random 150) 1000.)])
              (run-with-timer delay
                (lambda ()
                  (set! ran (cons (cons delay (- (seconds-now) start)) ran))
                  (when (= (length ran) n) (done))))))))
      (let ([ran (reverse ran)])
        (check (non-decreasing? (map car ran)))
        (check (for-all (lambda (r) (>= (cdr r) (car r))) ran)))
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

  (test "sleeping tasks wake in the order of their times, and none early"
    (let* ([woke '()]
           [start (seconds-now)]
           [tasks (map (lambda (i)
                         (let ([seconds (/ (random 100) 1000.)])
                           (spawn-task
                             (lambda ()
                               (sleep-for seconds)
                               (set! woke (cons (cons seconds (- (seconds-now) start)) woke))))))
                       (iota 100))])
      (for-each join-task tasks)
      (let ([woke (reverse woke)])
        (check-equal? 100 (length woke))
        (check (non-decreasing? (map car woke)))
        (check (for-all (lambda (w) (>= (cdr w) (car w))) woke)))))

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
