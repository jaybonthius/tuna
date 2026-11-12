(import (chezscheme) (tuna-test) (tuna core changes) (except (tuna core main-thread) exit)
        (prefix (only (tuna core replaced) dynamic-wind with-mutex) tuna:))

(define (burn n) (if (fx= n 0) 0 (fx+ 1 (burn (fx- n 1)))))

(define (in-thread thunk)
  (let ([result #f])
    (thread-join (fork-thread (lambda () (set! result (thunk)))))
    result))

(define (mutex-free? m)
  (and (mutex-acquire m #f)
       (begin (mutex-release m) #t)))

(define (tests)
  ;; Each round requests a quit after a random number of calls, so quits
  ;; land all over the winds and the mutex, their in and out included. The
  ;; round ends in a loop, so its quit always lands inside the guard.
  (test "on the main thread a quit never skips out or leaves the mutex held"
    (let ([inside 0] [skipped 0] [held 0] [quits 0] [m (make-mutex)])
      (define (in) (set! inside (+ inside 1)) (burn 3))
      (define (out) (burn 3) (set! inside (- inside 1)))
      (do ([i 0 (+ i 1)]) ((= i 20000))
        (guard (c [(quit-condition? c) (set! quits (+ quits 1))])
          (burn (random 1500))
          (request-quit!)
          (do ([j 0 (fx+ j 1)]) ((fx= j 10))
            (tuna:dynamic-wind in (lambda () (burn 5)) out)
            (tuna:with-mutex m (burn 5)))
          (let loop () (loop)))
        (unless (= inside 0)
          (set! skipped (+ skipped 1))
          (set! inside 0))
        (unless (mutex-free? m)
          (set! held (+ held 1))
          (mutex-release m)))
      (check-equal? 20000 quits)
      (check-equal? 0 skipped)
      (check-equal? 0 held)
      (check (quits-allowed))))

  (test "the body can be quit, and out runs after it"
    (let ([log '()] [m (make-mutex)])
      (define (note! e) (set! log (cons e log)))
      (check-equal? 'quit
        (guard (c [(quit-condition? c) 'quit])
          (tuna:dynamic-wind
            (lambda () (note! 'in))
            (lambda () (request-quit!) (let loop () (loop)))
            (lambda () (note! 'out)))))
      (check-equal? '(out in) log)
      (check-equal? 'quit
        (guard (c [(quit-condition? c) 'quit])
          (tuna:with-mutex m (request-quit!) (let loop () (loop)))))
      (check (mutex-free? m))
      (check (quits-allowed))))

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
    (check-equal? '(connect talk1 disconnect connect talk2 disconnect) (in-thread run))
    (check (quits-allowed)))

  (test "it returns the body's values, raises as Chez's does, and takes the critical form"
    (check-equal? '(1 2) (call-with-values (lambda () (tuna:dynamic-wind void (lambda () (values 1 2)) void)) list))
    (check-equal? '(1 2)
      (in-thread (lambda () (call-with-values (lambda () (tuna:dynamic-wind void (lambda () (values 1 2)) void)) list))))
    (check-equal? 3 (tuna:dynamic-wind #t void (lambda () 3) void))
    (check-equal? 4 (tuna:dynamic-wind #f void (lambda () 4) void))
    (check-raises assertion-violation? (tuna:dynamic-wind 'in void void))
    (check-raises assertion-violation? (tuna:with-mutex 'not-a-mutex 1))
    (check (quits-allowed))
    (let ([m (make-mutex)] [evaluated 0])
      (tuna:with-mutex (begin (set! evaluated (+ evaluated 1)) m) 'body)
      (check-equal? 1 evaluated)
      (check (mutex-free? m))))

  (test "in and out run with quits held off, and the body with the caller's"
    (let ([seen '()])
      (tuna:dynamic-wind
        (lambda () (set! seen (cons (quits-allowed) seen)))
        (lambda () (set! seen (cons (quits-allowed) seen)))
        (lambda () (set! seen (cons (quits-allowed) seen))))
      (check-equal? '(#f #t #f) seen)
      (set! seen '())
      (with-quits-allowed #f
        (tuna:dynamic-wind void (lambda () (set! seen (cons (quits-allowed) seen))) void))
      (check-equal? '(#f) seen))))

(post! (lambda ()
         (tests)
         (test-exit)))
(run-main-loop)
