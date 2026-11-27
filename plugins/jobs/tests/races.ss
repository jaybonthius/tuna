(import (tuna) (test) (test-runner) (timers) (jobs) (jobs-test) (jobs-test progress)
        (rename (only (chezscheme) sleep) (sleep chez:sleep)))

(define request-quit! (test-runner:running-task-canceller))

(define (sleep-ms ms) (chez:sleep (make-time 'time-duration (* ms 1000000) 0)))

(define (ignore v) (void))

;; The main thread is busy on purpose while a job works, so it keeps its
;; own deadline.
(define (spin-until done?)
  (let ([deadline (add-duration (current-time 'time-monotonic) (make-time 'time-duration 0 30))])
    (let loop ()
      (unless (done?)
        (when (time>? (current-time 'time-monotonic) deadline)
          (errorf 'spin-until "~s did not hold within 30 s" done?))
        (sleep-ms 1)
        (loop)))))

(jobs:define-worker (floods n emit) (import (jobs-test progress)) (do ([i 0 (+ i 1)]) ((= i n)) (emit i) (count!)))

(test "at most 64 of a job's values wait for the main thread: emit waits while the main thread is busy, and every value arrives in order"
  (let ([flood '()] [before (counted)])
    (jobs:start floods 1000 (lambda (v) (set! flood (cons v flood))))
    (spin-until (lambda () (>= (- (counted) before) 64)))
    (sleep-ms 50)
    (check-equal? 64 (- (counted) before))
    (test-runner:wait-until (lambda () (= (length flood) 1000)))
    (check-equal? (iota 1000) (reverse flood))))

(jobs:define-worker (count-up input emit)
  (do ([i 0 (+ i 1)]) ((= i (cdr input))) (emit (cons (car input) i))))

(test "values from many jobs at once each arrive on the main thread, each job's in order"
  (let ([received (make-vector 8 '())] [off-main 0])
    (do ([id 0 (+ id 1)]) ((= id 8))
      (jobs:start count-up (cons id 2000)
        (lambda (v)
          (unless (task? (current-task)) (set! off-main (+ off-main 1)))
          (vector-set! received (car v) (cons (cdr v) (vector-ref received (car v)))))))
    (test-runner:wait-until (lambda () (for-all (lambda (l) (= (length l) 2000)) (vector->list received))))
    (check-equal? 0 off-main)
    (check (for-all (lambda (l) (equal? (reverse l) (iota 2000))) (vector->list received)))))

(jobs:define-worker (spin x emit) (let loop () (loop)))

(test "stopping a job before its body runs, or while it runs, ends it with stopped and leaves the others running"
  (let* ([ended '()]
         [start-spin (lambda () (jobs:start spin 0 ignore (lambda (e) (set! ended (cons e ended)))))]
         [early (map (lambda (i) (start-spin)) (iota 10))]
         [late (map (lambda (i) (start-spin)) (iota 10))])
    (for-each jobs:stop! early)
    (test-runner:wait-until (lambda () (= (length ended) 10)))
    (timers:sleep 0.05)
    (check-equal? (make-list 10 'stopped) ended)
    (for-each jobs:stop! late)
    (test-runner:wait-until (lambda () (= (length ended) 20)))
    (check-equal? (make-list 20 'stopped) ended)))

(jobs:define-worker (bounce x emit receive) (let loop () (emit (receive)) (loop)))

(test "vectors frozen on several threads at once, while a job sends values holding them back, all arrive"
  (let* ([bounced 0] [bouncing (jobs:start bounce 0 (lambda (v) (set! bounced (+ bounced 1))))])
    (do ([k 0 (+ k 1)]) ((= k 4))
      (fork-task
        (lambda (restore)
          (do ([i 0 (+ i 1)]) ((= i 2000))
            (jobs:send! bouncing (list (jobs:freeze (vector k i)) (jobs:freeze (vector (list i)))))))))
    (test-runner:wait-until (lambda () (= bounced 8000)))
    (jobs:stop! bouncing)
    (check-equal? 8000 bounced)))

(jobs:define-worker (echo x emit receive)
  (let loop ()
    (let ([v (receive)])
      (unless (eq? v 'stress) (emit v)))
    (loop)))

(test "quits landing in the plugin's code on the main thread, sending, leave no mutex held: the job still answers"
  (let* ([answers '()]
         [echoing (jobs:start echo 0 (lambda (v) (set! answers (cons v answers))))]
         [armed (box #f)] [quitting (box #t)] [quits 0])
    ;; The thread asks for a quit only while the main thread has armed it
    ;; inside the guard, so every quit lands there.
    (fork-task
      (lambda (restore)
        (let loop ()
          (when (unbox quitting)
            (sleep-ms 1)
            (when (box-cas! armed #t #f) (request-quit!))
            (loop)))))
    (let retry ()
      (when (< quits 500)
        (guard (c [(cancelled? c) (set! quits (+ quits 1))])
          (set-box! armed #t)
          (let loop ()
            (jobs:send! echoing 'stress)
            (loop)))
        (retry)))
    (set-box! quitting #f)
    (jobs:send! echoing 'after)
    (test-runner:wait-until (lambda () (memq 'after answers)))
    (check-equal? '(after) answers)
    (jobs:stop! echoing)))

(jobs:define-worker (flood n emit) (let loop () (emit n) (loop)))

(test "quits asked for as fast as a thread can, while the main thread delivers a job's values, lose no more than those deliveries"
  (let* ([delivered 0]
         [counting (jobs:start flood 0 (lambda (v) (set! delivered (+ delivered 1))))]
         [reported 0]
         [count-quits (lambda (next c) (if (cancelled? c) (set! reported (+ reported 1)) (next c)))])
    (advice-add! report count-quits)
    ;; The storm starts from a task spawned by this one, which runs only
    ;; once this one has paused, so no quit lands in the test; it goes on
    ;; until a quit has been reported.
    (suspend
      (lambda (resume)
        (spawn-task
          (lambda (restore)
            (fork-task
              (lambda (restore)
                (let ([until (+ (real-time) 2000)] [deadline (+ (real-time) 30000)])
                  (let loop ()
                    (when (and (< (real-time) deadline) (or (< (real-time) until) (= reported 0)))
                      (request-quit!)
                      (loop))))
                (resume void)))))))
    (let ([before delivered])
      (test-runner:wait-until (lambda () (> delivered before))))
    (advice-remove! report count-quits)
    (check (> reported 0))
    (jobs:stop! counting)))

(jobs:define-worker (doubled x emit) (emit (* x 2)))

(test "a worker's first start compiles it with quits held off, so quits asked for at every tick cannot keep it from compiling"
  (let* ([asking #f]
         [ask-at-each-tick (lambda (tick) (when asking (cancel-task (current-task))) (tick))])
    (advice-add! tick ask-at-each-tick)
    (check-equal? 'started
      (let try ([tries 0])
        (if (= tries 20)
            'never-started
            (guard (c [(cancelled? c) (set! asking #f) (try (+ tries 1))])
              (set! asking #t)
              (jobs:start doubled 21 ignore)
              (set! asking #f)
              ;; A quit asked for where quits wait lands up to a thousand
              ;; calls later, so the guard holds a while after the asking.
              (let settle ([n 0]) (when (< n 100000) (settle (+ n 1))))
              'started))))
    (advice-remove! tick ask-at-each-tick))
  (check-equal? '((42) #f) (jobs-test:finished doubled 21)))

(jobs:define-worker (nothing x emit) (void))

(jobs:define-worker (echo-once x emit) (emit x))

(test "a quit landing in jobs:start or jobs:stop! leaves no job half started: every job started ends"
  (let ([started 0] [finished-jobs 0] [landed 0])
    (do ([i 0 (+ i 1)]) ((= i 100))
      (guard (c [(cancelled? c) (set! landed (+ landed 1))])
        (cancel-task (current-task))
        (let loop ()
          (jobs:stop! (jobs:start nothing 0 ignore (lambda (e) (set! finished-jobs (+ finished-jobs 1)))))
          (set! started (+ started 1))
          (loop))))
    (check-equal? 100 landed)
    (check (> started 0))
    (test-runner:wait-until (lambda () (>= finished-jobs started)))
    (check-equal? '((still-working) #f) (jobs-test:finished echo-once 'still-working))))

(jobs:define-worker (many n emit) (do ([i 0 (+ i 1)]) ((= i n)) (emit i)))

(test "quits about every millisecond while jobs deliver many values lose no value and no end: on-result and on-end run with quits held off"
  (let* ([results 0] [ends 0] [armed (box #f)] [quitting (box #t)]
         [drop-quits (lambda (next c) (unless (cancelled? c) (next c)))])
    (advice-add! report drop-quits)
    (fork-task
      (lambda (restore)
        (let loop ()
          (when (unbox quitting)
            (chez:sleep (make-time 'time-duration 200000 0))
            (when (box-cas! armed #t #f) (request-quit!))
            (loop)))))
    (do ([k 0 (+ k 1)]) ((= k 20))
      (jobs:start many 1000
        (lambda (v)
          (let busy ([i 0]) (when (< i 3000) (busy (+ i 1))))
          (set! results (+ results 1)))
        (lambda (ended) (set! ends (+ ends 1)))))
    ;; The thread asks for a quit only while this task is armed, inside the
    ;; guard; the quit lands in whichever task runs then.
    (let again ()
      (guard (c [(cancelled? c) (again)])
        (let loop ([n 0])
          (unless (or (and (= ends 20) (= results 20000)) (= n 30000))
            (set-box! armed #t)
            (timers:sleep 0.001)
            (loop (+ n 1))))
        (set-box! armed #f)
        (timers:sleep 0.05)))
    (set-box! quitting #f)
    (advice-remove! report drop-quits)
    (check-equal? 20000 results)
    (check-equal? 20 ends)))
