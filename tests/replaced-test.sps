(import (chezscheme) (tuna-test) (kernel-test)
        (only (tuna) spawn-task fork-task join-task cancel-task stop-task cancelled? call-with-cancellation-masked)
        (prefix (only (tuna core replaced) dynamic-wind with-mutex) tuna:))

(define (burn n) (if (fx= n 0) 0 (fx+ 1 (burn (fx- n 1)))))

(define (in-thread thunk)
  (let ([result #f])
    (join-task (fork-task (lambda (restore) (set! result (thunk)))))
    result))

(define (mutex-free? m)
  (and (mutex-acquire m #f)
       (begin (mutex-release m) #t)))

(define (ended t) (call-with-values (lambda () (join-task t)) list))


(define (tests)
  ;; A stop may land in in itself, and then out does not run; that is the
  ;; winder the stop lands in, which it skips.
  (test "a cancel never skips out, and neither a cancel nor a stop leaves the mutex held"
    (let ([inside 0] [skipped 0] [held 0] [ended 0] [m (make-mutex)])
      (define (in) (set! inside (+ inside 1)) (burn 3))
      (define (out) (burn 3) (set! inside (- inside 1)))
      (do ([i 0 (+ i 1)]) ((= i 300))
        (let ([t (spawn-task
                   (lambda (restore)
                     (let loop ()
                       (tuna:dynamic-wind in (lambda () (burn 5)) out)
                       (tuna:with-mutex m (burn 5))
                       (loop))))])
          (fork-task (lambda (restore) (sleep-ms (random 3)) (if (even? i) (cancel-task t) (stop-task t))))
          (join-task t)
          (set! ended (+ ended 1)))
        (unless (= inside 0)
          (when (even? i) (set! skipped (+ skipped 1)))
          (set! inside 0))
        (unless (mutex-free? m)
          (set! held (+ held 1))
          (mutex-release m)))
      (check-equal? 300 ended)
      (check-equal? 0 skipped)
      (check-equal? 0 held)))

  (test "the body can be cancelled, and out runs after it"
    (let ([log '()] [m (make-mutex)])
      (define (note! e) (set! log (cons e log)))
      (let ([t (spawn-task
                 (lambda (restore)
                   (tuna:dynamic-wind
                     (lambda () (note! 'in))
                     (lambda () (let loop () (loop)))
                     (lambda () (note! 'out)))))])
        (fork-task (lambda (restore) (sleep-ms 5) (cancel-task t)))
        (check-equal? 'cancelled (car (ended t))))
      (check-equal? '(out in) log)
      (let ([t (spawn-task (lambda (restore) (tuna:with-mutex m (let loop () (loop)))))])
        (fork-task (lambda (restore) (sleep-ms 5) (cancel-task t)))
        (check-equal? 'cancelled (car (ended t))))
      (check (mutex-free? m))))

  ;; R6RS's own example of dynamic-wind, re-entered through a continuation.
  (test "a continuation re-enters the body through in, on the main thread and on another"
    (define (run)
      (let ([path '()] [c #f])
        (let ([add (lambda (s) (set! path (cons s path)))])
          (tuna:dynamic-wind
            (lambda () (add 'connect))
            (lambda () (add (call/cc (lambda (c0) (set! c c0) 'talk1))))
            (lambda () (add 'disconnect)))
          (if (< (length path) 4)
              (c 'talk2)
              (reverse path)))))
    (check-equal? '(connect talk1 disconnect connect talk2 disconnect) (run))
    (check-equal? '(connect talk1 disconnect connect talk2 disconnect) (in-thread run)))

  (test "it returns the body's values, raises as Chez's does, and takes the critical form"
    (check-equal? '(1 2) (call-with-values (lambda () (tuna:dynamic-wind void (lambda () (values 1 2)) void)) list))
    (check-equal? '(1 2)
      (in-thread (lambda () (call-with-values (lambda () (tuna:dynamic-wind void (lambda () (values 1 2)) void)) list))))
    (check-equal? 3 (tuna:dynamic-wind #t void (lambda () 3) void))
    (check-equal? 4 (tuna:dynamic-wind #f void (lambda () 4) void))
    (check-raises assertion-violation? (tuna:dynamic-wind 'in void void))
    (check-raises assertion-violation? (tuna:with-mutex 'not-a-mutex 1))
    (let ([m (make-mutex)] [evaluated 0])
      (tuna:with-mutex (begin (set! evaluated (+ evaluated 1)) m) 'body)
      (check-equal? 1 evaluated)
      (check (mutex-free? m))))

  (test "in and out run masked, and the body with the caller's mask"
    (let* ([log '()]
           [t (spawn-task
                (lambda (restore)
                  (tuna:dynamic-wind
                    (lambda () (burn 3000000) (set! log (cons 'in-done log)))
                    (lambda () (set! log (cons 'body log)) (let loop () (loop)))
                    void)))])
      (fork-task (lambda (restore) (sleep-ms 1) (cancel-task t)))
      (check-equal? 'cancelled (car (ended t)))
      (check-equal? '(body in-done) log))))

(run-in-kernel
  (lambda ()
    (tests)
    (delete-test-folder!)
    (test-exit)))
