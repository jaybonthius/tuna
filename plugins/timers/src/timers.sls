#!tuna
;; A timer is a task of the owner that made it, paused until it is due; the
;; clock thread resumes it. So a timer goes when its owner unloads, with
;; nothing of its own to take back.
(define-record-type (%timer %make-timer timer?)
  (nongenerative)
  (sealed #t)
  (fields procedure* repeat idle mutex (mutable task) (mutable due) (mutable waiting?) (mutable dead?))
  (protocol
    (lambda (new)
      (lambda (procedure repeat idle due)
        (new procedure repeat idle (make-mutex) #f due #f #f)))))

(define (procedure t)
  (%check-timer 'timers:procedure t)
  (%timer-procedure* t))

;; The clock's state: what waits for a time, and the idle timers. The main
;; thread and the clock thread both change it, under the mutex.
(define %mutex (make-mutex))
(define %changed (make-condition))
(define %sleepers (box '()))
(define %idlers (box '()))
(define %live (box '()))
(define %idle-since (box #f))

(define (%monotonic-ns)
  (let ([t (current-time 'time-monotonic)])
    (+ (* (time-second t) 1000000000) (time-nanosecond t))))

(define (%seconds->ns seconds) (exact (round (* seconds 1000000000))))

(define (%ns->duration ns)
  (make-time 'time-duration (remainder ns 1000000000) (quotient ns 1000000000)))

(define (%check-seconds who seconds)
  (unless (and (real? seconds) (not (negative? seconds)) (finite? seconds))
    (assertion-violation who "not a number of seconds" seconds)))

(define (%check-timer who t)
  (unless (timer? t) (assertion-violation who "not a timer" t)))

(define (%wake-due! now)
  (let-values ([(ready waiting) (partition (lambda (s) (<= (car s) now)) (unbox %sleepers))])
    (set-box! %sleepers waiting)
    (for-each (lambda (s) ((cdr s) void)) (list-sort (lambda (a b) (< (car a) (car b))) ready))
    (let ([next (fold-left (lambda (next s) (if (or (not next) (< (car s) next)) (car s) next)) #f waiting)]
          [since (unbox %idle-since)])
      (if since
          (let-values ([(ready waiting)
                        (partition (lambda (i) (and (not (eqv? (caddr i) since)) (<= (+ since (car i)) now)))
                                   (unbox %idlers))])
            (set-box! %idlers waiting)
            (for-each (lambda (i) ((cadr i) void)) ready)
            (fold-left (lambda (next i)
                         (let ([at (+ since (car i))])
                           (if (or (eqv? (caddr i) since) (and next (>= at next))) next at)))
                       next waiting))
          next))))

(define (%clock restore)
  (with-mutex %mutex
    (let loop ()
      (let ([next (%wake-due! (%monotonic-ns))])
        (condition-wait %changed %mutex (and next (%ns->duration (max 0 (- next (%monotonic-ns))))))
        (loop)))))

(define (%wait-until! due)
  (suspend
    (lambda (resume)
      (with-mutex %mutex
        (set-box! %sleepers (cons (cons due resume) (unbox %sleepers)))
        (condition-signal %changed)))))

;; A timer that has run in this idle period, which began at last, waits
;; for the next one.
(define (%wait-idle! ns last)
  (suspend
    (lambda (resume)
      (with-mutex %mutex
        (set-box! %idlers (cons (list ns resume last) (unbox %idlers)))
        (condition-signal %changed)))))

(define (%remove-live! t)
  (with-mutex %mutex (set-box! %live (remq t (unbox %live)))))

;; The timer's task stops waiting and reads dead? in one section under the
;; timer's mutex: cancel! either finds it waiting, and then the task sees
;; dead? and skips the procedure, or finds it past that section, and then
;; the procedure runs to its end.
(define (%due? t)
  (not (with-mutex (%timer-mutex t)
         (%timer-waiting?-set! t #f)
         (%timer-dead? t))))

(define (%run-once t)
  (guard (c [(cancelled? c) (raise c)] [#t (report c)])
    ((%timer-procedure* t))))

;; The first due time after now on the timer's own schedule, so a timer
;; that fell behind runs once and then keeps its rhythm.
(define (%next-due due repeat now)
  (+ due (* repeat (+ 1 (quotient (- now due) repeat)))))

;; A cancel of the timer is the timer's own business, so it ends the
;; task quietly; any other cancel goes on as usual. The timer leaves the
;; live list as its task ends, not in a winder, which would run at each
;; pause; a task stopped with its owner leaves it, and live skips it.
(define %cancelled-timer (list 'cancelled-timer))

(define (%timer-body t)
  (guard (c [(and (cancelled? c) (eq? (cancelled-reason c) %cancelled-timer)) (%remove-live! t)]
            [#t (%remove-live! t) (raise c)])
    (let loop ([last #f])
      (with-mutex (%timer-mutex t) (%timer-waiting?-set! t #t))
      (if (%timer-idle t) (%wait-idle! (%timer-idle t) last) (%wait-until! (%timer-due t)))
      (when (%due? t)
        (let ([period (unbox %idle-since)])
          (%run-once t)
          (cond
            [(%timer-repeat t)
             (%timer-due-set! t (%next-due (%timer-due t) (%timer-repeat t) (%monotonic-ns)))
             (loop #f)]
            [(%timer-idle t) (loop period)]))))
    (%remove-live! t)))

(define (%start! t)
  (call-with-cancellation-masked
    (lambda (restore)
      (with-mutex %mutex (set-box! %live (cons t (unbox %live))))
      (%timer-task-set! t (spawn-task (lambda (restore) (restore (lambda () (%timer-body t))))))))
  t)

(define run-after
  (case-lambda
    [(seconds proc) (run-after seconds proc #f)]
    [(seconds proc repeat)
     (%check-seconds 'timers:run-after seconds)
     (unless (procedure? proc) (assertion-violation 'timers:run-after "not a procedure" proc))
     (unless (or (not repeat) (and (real? repeat) (positive? repeat) (finite? repeat)))
       (assertion-violation 'timers:run-after "not a number of seconds to repeat after" repeat))
     (%start! (%make-timer proc (and repeat (max 1 (%seconds->ns repeat))) #f
                (+ (%monotonic-ns) (%seconds->ns seconds))))]))

(define (run-when-idle seconds proc)
  (%check-seconds 'timers:run-when-idle seconds)
  (unless (procedure? proc) (assertion-violation 'timers:run-when-idle "not a procedure" proc))
  (%start! (%make-timer proc #f (%seconds->ns seconds) #f)))

;; As Emacs's cancel-timer: a timer whose procedure is running runs to its
;; end and does not run again.
(define (cancel! t)
  (%check-timer 'timers:cancel! t)
  (let ([waiting? (with-mutex (%timer-mutex t)
                    (%timer-dead?-set! t #t)
                    (%timer-waiting? t))])
    (when waiting? (cancel-task (%timer-task t) %cancelled-timer))))

(define (live)
  (filter (lambda (t) (not (eq? (task-state (%timer-task t)) 'done)))
          (reverse (with-mutex %mutex (unbox %live)))))

(define (sleep seconds)
  (%check-seconds 'timers:sleep seconds)
  (%wait-until! (+ (%monotonic-ns) (%seconds->ns seconds)))
  (void))

;; An idle timer runs once in each idle period, so becoming busy makes each
;; ready to run again.
(define (set-idle! idle?)
  (unless (boolean? idle?) (assertion-violation 'timers:set-idle! "not a boolean" idle?))
  (with-mutex %mutex
    (cond
      [idle? (unless (unbox %idle-since)
               (set-box! %idle-since (%monotonic-ns))
               (condition-signal %changed))]
      [else (set-box! %idle-since #f)])))

(define (idle-seconds)
  (let ([since (unbox %idle-since)])
    (and since (/ (- (%monotonic-ns) since) 1e9))))

(define %clock-task (fork-task %clock))

;; The configuration's and REPLs' timers wait on this clock too, and they
;; are not modules that unload before timers does.
(on-unload
  (lambda ()
    (for-each (lambda (t) (cancel! t)) (live))
    (with-mutex %mutex
      (for-each (lambda (s) (s void)) (map cdr (unbox %sleepers)))
      (set-box! %sleepers '()))))

(record-writer (record-type-descriptor %timer)
  (lambda (t p wr) (display "#<timer>" p)))
