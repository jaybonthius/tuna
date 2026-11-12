(library (tuna timers)
  (export
    sleep-for
    run-with-timer
    run-with-idle-timer
    cancel-timer!
    timers
    timer-procedure
    timer?
    set-idle!
    idle-seconds)
  (import (chezscheme) (tuna core changes) (only (tuna core main-thread) post-task! suspend))

  ;; A one-shot timer stays in timers until its task starts, so cancelling
  ;; it before then stops it.
  (define-record-type timer
    (nongenerative)
    (sealed #t)
    (fields (immutable procedure timer-thunk) owner repeat idle
            (mutable due)
            (mutable waiting?)
            (mutable ran-idle?)
            (mutable live?)
            (mutable change))
    (protocol
      (lambda (new)
        (lambda (procedure owner repeat idle due)
          (new procedure owner repeat idle due #f #f #t #f)))))

  ;; The main thread alone changes live-timers, and replaces the list
  ;; rather than changing it, so timers reads it on any thread without the
  ;; mutex.
  (define timers-mutex (make-mutex))
  (define timers-changed (make-condition))
  (define live-timers '())
  (define sleepers '())
  (define idle-since #f)
  (define timer-thread-started? #f)

  (define (monotonic-ns)
    (let ([t (current-time 'time-monotonic)])
      (+ (* (time-second t) 1000000000) (time-nanosecond t))))

  (define (seconds->ns seconds)
    (exact (round (* seconds 1000000000))))

  (define (ns->duration ns)
    (make-time 'time-duration (remainder ns 1000000000) (quotient ns 1000000000)))

  (define (check-seconds who seconds)
    (unless (and (real? seconds) (not (negative? seconds)) (finite? seconds))
      (assertion-violation who "not a number of seconds" seconds)))

  (define (check-procedure who proc)
    (unless (procedure? proc)
      (assertion-violation who "not a procedure" proc)))

  ;; The first due time after now on the timer's own schedule, so a timer
  ;; that fell behind runs once and then keeps its rhythm.
  (define (next-due due repeat now)
    (+ due (* repeat (+ 1 (quotient (- now due) repeat)))))

  (define (posting t)
    (lambda () (post-task! (lambda () (run-timer! t)) (timer-owner t) #f)))

  ;; Called with timers-mutex held.
  (define (take-due! now)
    (let ([due '()] [next #f])
      (define (due! at run) (set! due (cons (cons at run) due)))
      (define (later! at) (when (or (not next) (< at next)) (set! next at)))
      (let-values ([(ready waiting) (partition (lambda (s) (<= (car s) now)) sleepers)])
        (set! sleepers waiting)
        (for-each (lambda (s) (let ([resume (cdr s)]) (due! (car s) (lambda () (resume void))))) ready)
        (for-each (lambda (s) (later! (car s))) waiting))
      (for-each
        (lambda (t)
          (cond
            [(timer-idle t)
             (when (and idle-since (not (timer-ran-idle? t)))
               (let ([at (+ idle-since (timer-idle t))])
                 (cond
                   [(<= at now)
                    (timer-ran-idle?-set! t #t)
                    (due! at (posting t))]
                   [else (later! at)])))]
            [(<= (timer-due t) now)
             (unless (timer-waiting? t)
               (timer-waiting?-set! t #t)
               (due! (timer-due t) (posting t)))
             (let ([repeat (timer-repeat t)])
               (when repeat
                 (timer-due-set! t (next-due (timer-due t) repeat now))
                 (later! (timer-due t))))]
            [else (later! (timer-due t))]))
        live-timers)
      (values (map cdr (list-sort (lambda (a b) (< (car a) (car b))) due)) next)))

  (define (run-timer-thread)
    (let loop ()
      (for-each
        (lambda (run) (run))
        (with-mutex timers-mutex
          (let wait ()
            (let-values ([(due next) (take-due! (monotonic-ns))])
              (cond
                [(pair? due) due]
                [else
                 (condition-wait timers-changed timers-mutex
                   (and next (ns->duration (max 0 (- next (monotonic-ns))))))
                 (wait)])))))
      (loop)))

  ;; Called with timers-mutex held.
  (define (wake-timer-thread!)
    (unless timer-thread-started?
      (set! timer-thread-started? #t)
      (fork-thread run-timer-thread))
    (condition-signal timers-changed))

  (define (remove-timer! t)
    (with-quit-safe-mutex timers-mutex
      (timer-live?-set! t #f)
      (set! live-timers (remq t live-timers))))

  (define (add-timer! who t)
    (with-quits-allowed #f
      (timer-change-set! t (record-change! who 'timer t #f (lambda () (remove-timer! t)) void))
      (with-quit-safe-mutex timers-mutex
        (set! live-timers (append live-timers (list t)))
        (wake-timer-thread!)))
    t)

  ;; A timer cancelled after its run was posted does not run.
  (define (run-timer! t)
    (when (timer-live? t)
      (with-quits-allowed #f
        (cond
          [(timer-repeat t) (with-quit-safe-mutex timers-mutex (timer-waiting?-set! t #f))]
          [(timer-idle t) (void)]
          [else (forget-change! (timer-change t)) (remove-timer! t)]))
      ((timer-thunk t))))

  (define run-with-timer
    (case-lambda
      [(seconds proc) (run-with-timer seconds proc #f)]
      [(seconds proc repeat)
       (check-seconds 'run-with-timer seconds)
       (check-procedure 'run-with-timer proc)
       (unless (or (not repeat) (and (real? repeat) (positive? repeat) (finite? repeat)))
         (assertion-violation 'run-with-timer "not a number of seconds to repeat after" repeat))
       (add-timer! 'run-with-timer
         (make-timer proc (current-owner-record) (and repeat (max 1 (seconds->ns repeat))) #f
           (+ (monotonic-ns) (seconds->ns seconds))))]))

  (define (run-with-idle-timer seconds proc)
    (check-seconds 'run-with-idle-timer seconds)
    (check-procedure 'run-with-idle-timer proc)
    (add-timer! 'run-with-idle-timer
      (make-timer proc (current-owner-record) #f (seconds->ns seconds) #f)))

  (define (check-timer who t)
    (unless (timer? t)
      (assertion-violation who "not a timer" t)))

  (define (cancel-timer! t)
    (check-timer 'cancel-timer! t)
    (check-main-thread 'cancel-timer!)
    (when (timer-live? t)
      (take-back! (timer-change t))))

  (define (timers)
    (list-copy live-timers))

  (define (timer-procedure t)
    (check-timer 'timer-procedure t)
    (timer-thunk t))

  (define (sleep-for seconds)
    (check-seconds 'sleep-for seconds)
    (let ([due (+ (monotonic-ns) (seconds->ns seconds))])
      (suspend
        (lambda (resume)
          (with-quit-safe-mutex timers-mutex
            (set! sleepers (cons (cons due resume) sleepers))
            (wake-timer-thread!)))))
    (void))

  ;; An idle timer runs once in each idle period, so becoming busy makes
  ;; each ready to run again.
  (define (set-idle! idle?)
    (unless (boolean? idle?)
      (assertion-violation 'set-idle! "not a boolean" idle?))
    (with-quit-safe-mutex timers-mutex
      (cond
        [idle?
         (unless idle-since
           (set! idle-since (monotonic-ns))
           (condition-signal timers-changed))]
        [else
         (set! idle-since #f)
         (for-each (lambda (t) (timer-ran-idle?-set! t #f)) live-timers)])))

  (define (idle-seconds)
    (let ([since idle-since])
      (and since (/ (- (monotonic-ns) since) 1e9))))

  (record-writer (record-type-descriptor timer)
    (lambda (t p wr) (display "#<timer>" p))))
