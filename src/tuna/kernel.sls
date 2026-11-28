(library (tuna kernel)
  (export
    on-main-thread?
    check-main-thread

    owner?
    owner-name
    owner-kind
    owner-number
    owner-state
    owner-state-set!
    owner-rank
    owner-rank-set!
    owner-live?
    owner<?
    kernel-owner
    make-owner
    made-owner
    new-module-owner
    made-owners
    made-owner-name?
    current-owner
    changing-owner
    record-change!
    forget-change!
    owner-change-records
    change-kind
    change-detail
    change-thing
    change-undo
    (rename (owner-changes* owner-changes) (owner-threads* owner-threads))
    on-unload

    task?
    (rename (task-state* task-state) (task-owner* task-owner) (task-frames* task-frames))
    task-cleanup?
    task-request
    task-kind
    task-in-code-of?
    live-tasks
    current-task
    spawn-task
    spawn-kernel-task
    spawn-cleanup-task
    fork-task
    suspend
    join-task
    cancel-task
    stop-task
    call-with-cancellation-masked
    call-as-owner
    call-entered-as
    mark-unloading-code!
    notify-unload-waiters!
    add-unload-waiter!
    begin-body!
    finish-body!
    drop-body!
    body-running
    running-body-records
    running-body-instance
    forget-raised-in-body!
    unloaded-condition
    task-on-thread?
    changeable-definer
    tuna-dynamic-wind
    tuna-condition-wait
    tuna-sleep
    tuna-register-signal-handler
    exit
    enqueue!
    run-main-loop
    set-exit-runner!
    exit-unloading?
    begin-exit-unloading!
    stop-main-tasks!
    finish-exit!
    stop-running-cleanup!

    definition-wrapper
    changeable?
    define-changeable!
    kernel-define!
    retarget!
    retarget-changed!
    take-back-definitions!
    definition-symbol-of
    advice-add!
    advice-remove!
    override-set!
    override-remove!
    definition-changes
    definition-documentation
    set-definition-documentation!

    report
    report-owner
    report-safely
    report-warning
    report-warning-once
    call-reporting
    tick
    batch-ended
    module-loaded
    owner-unloading
    exit-anyway?)
  (import (except (chezscheme) exit) (prefix (only (chezscheme) exit) chez:) (tuna conditions))

  ;;; Threads

  ;; The thread's record is written once per thread, so reading the
  ;; running task costs one thread-parameter read. A thread Chez forked
  ;; outside the kernel holds its parent's record until it needs its own,
  ;; and acts for no owner.
  (define-record-type thread-state
    (nongenerative)
    (sealed #t)
    (fields id main? (mutable task) (mutable frames) (mutable kernel-depth)))

  (define main-thread-id (get-thread-id))
  (define main-state (make-thread-state main-thread-id #t #f '() 0))
  (define current-thread-state (make-thread-parameter main-state))

  (define (this-thread)
    (let ([s (current-thread-state)])
      (if (fx= (thread-state-id s) (get-thread-id))
          s
          (own-thread-state!))))

  (define (own-thread-state!)
    (let ([s (make-thread-state (get-thread-id) #f #f '() 0)])
      (current-thread-state s)
      s))

  (define (on-main-thread?) (fx= (get-thread-id) main-thread-id))

  (define (check-main-thread who)
    (unless (on-main-thread?)
      (assertion-violation who "only the main thread changes owners and modules")))

  ;; Bookkeeping that another task must not see half done runs with
  ;; requests deferred, not with interrupts disabled, so it may wait for a
  ;; mutex and a collection may run meanwhile. Nothing in it raises.
  (define-syntax kernel-section
    (syntax-rules ()
      [(_ s e1 e2 ...)
       (let ([ts s])
         (thread-state-kernel-depth-set! ts (fx+ (thread-state-kernel-depth ts) 1))
         (let ([v (begin e1 e2 ...)])
           (thread-state-kernel-depth-set! ts (fx- (thread-state-kernel-depth ts) 1))
           v))]))

  (define-syntax with-kernel-mutex
    (syntax-rules ()
      [(_ m e1 e2 ...)
       (kernel-section (this-thread)
         (mutex-acquire m)
         (let ([v (begin e1 e2 ...)])
           (mutex-release m)
           v))]))

  ;;; Owners

  (define-record-type (owner make-owner* owner?)
    (nongenerative)
    (sealed #t)
    (fields name kind number (mutable rank) (mutable state) (mutable changes) (mutable threads))
    (protocol
      (lambda (new)
        (lambda (name kind number rank)
          (new name kind number rank 'loaded '() '())))))

  (define kernel-owner (make-owner* '(tuna) 'kernel 1 0))

  (define (owner-live? o)
    (unless (owner? o) (assertion-violation 'owner-live? "not an owner" o))
    (eq? (owner-state o) 'loaded))

  (define (owner<? a b)
    (unless (owner? a) (assertion-violation 'owner<? "not an owner" a))
    (unless (owner? b) (assertion-violation 'owner<? "not an owner" b))
    (< (owner-rank a) (owner-rank b)))

  (define (owner-name-list? x)
    (and (pair? x) (list? x) (for-all symbol? x)))

  ;; Owners made by make-owner rank above every module, in the order their
  ;; names were first made, so a name made again keeps its place. Any
  ;; thread's module lookup asks whether a name was made, so the main
  ;; thread replaces the table whole and never changes it in place.
  (define made-band (expt 2 50))
  (define made-ranks (hashtable-copy (make-hashtable equal-hash equal?) #f))
  (define made-live (make-hashtable equal-hash equal?))
  (define instance-numbers (make-hashtable equal-hash equal?))

  (define (next-number! name)
    (let ([n (fx+ (hashtable-ref instance-numbers name 0) 1)])
      (hashtable-set! instance-numbers name n)
      n))

  (define (make-owner name)
    (unless (owner-name-list? name)
      (assertion-violation 'make-owner "not an owner name, a list of symbols" name))
    (check-main-thread 'make-owner)
    (when (equal? name '(tuna))
      (assertion-violation 'make-owner "(tuna) is the kernel's name" name))
    (when (hashtable-contains? latest-module-instances name)
      (assertion-violation 'make-owner "a module has that name" name))
    (when (live-made-owner name)
      (assertion-violation 'make-owner "an owner of that name is live" name))
    (let ([rank (or (hashtable-ref made-ranks name #f)
                    (let ([r (+ made-band (hashtable-size made-ranks))] [ranks (hashtable-copy made-ranks #t)])
                      (hashtable-set! ranks name r)
                      (set! made-ranks (hashtable-copy ranks #f))
                      r))])
      (let ([o (make-owner* name 'made (next-number! name) rank)])
        (hashtable-set! made-live name o)
        o)))

  (define (made-owner-name? name) (hashtable-contains? made-ranks name))

  (define (live-made-owner name)
    (let ([o (hashtable-ref made-live name #f)])
      (and o (memq (owner-state o) '(loaded unloading)) o)))

  (define (made-owner name)
    (unless (owner-name-list? name)
      (assertion-violation 'made-owner "not an owner name, a list of symbols" name))
    (check-main-thread 'made-owner)
    (live-made-owner name))

  (define (made-owners)
    (filter (lambda (o) (memq (owner-state o) '(loaded unloading)))
            (vector->list (hashtable-values made-live))))

  (define latest-module-instances (make-hashtable equal-hash equal?))

  (define (new-module-owner name rank)
    (let ([o (make-owner* name 'module (next-number! name) rank)])
      (hashtable-set! latest-module-instances name o)
      o))

  ;;; Changes, newest first

  (define-record-type change
    (nongenerative)
    (sealed #t)
    (fields kind thing detail undo))

  (define (owner-change-records o) (owner-changes o))

  (define (record-change! owner kind thing detail undo)
    (let ([c (make-change kind thing detail undo)])
      (owner-changes-set! owner (cons c (owner-changes owner)))
      c))

  (define (forget-change! owner c)
    (owner-changes-set! owner (remq c (owner-changes owner))))

  (define (owner-changes* o)
    (unless (owner? o) (assertion-violation 'owner-changes "not an owner" o))
    (map (lambda (c)
           (let ([detail (change-detail c)])
             (list (change-kind c) (change-thing c) (if (weak-pair? detail) (car detail) detail))))
         (owner-changes o)))

  ;; The owner that code changing something acts for: it must be live, and
  ;; the kernel makes no change of its own, since nothing would take it back.
  (define (changing-owner who)
    (let ([o (current-owner)])
      (cond
        [(not o) (assertion-violation who "this code acts for no owner; name one with call-as-owner")]
        [(eq? o kernel-owner) (assertion-violation who "this code acts for no module")]
        [(not (eq? (owner-state o) 'loaded)) (raise (unloaded-condition who o))]
        [else o])))

  (define (unloaded-condition who o)
    (condition (make-unloaded o) (make-who-condition who)
      (make-message-condition
        (format (if (eq? (owner-kind o) 'module) "module ~s is unloaded" "~s is unloaded") (owner-name o)))))

  (define (on-unload thunk)
    (unless (procedure? thunk) (assertion-violation 'on-unload "not a procedure" thunk))
    (check-main-thread 'on-unload)
    (let ([owner (changing-owner 'on-unload)])
      (kernel-section (this-thread) (record-change! owner 'unload-action thunk #f void)))
    (void))

  ;;; Tasks

  ;; The frames live in the record so an unload finds a task paused inside
  ;; a layer; pause holds a token so a resume continues only its own
  ;; pause.
  (define-record-type task
    (nongenerative)
    (sealed #t)
    (fields proc owner thread kind lock
            (mutable state) (mutable how) (mutable detail) (mutable joiners)
            (mutable mask) (mutable cancel) (mutable stop?) (mutable unloaded) (mutable frames)
            (mutable switching?) (mutable continuation) (mutable pause) (mutable resumed)
            (mutable waiting-on) (mutable escape) (mutable stopping?) (mutable winding)
            (mutable stop-deferred?))
    (protocol
      (lambda (new)
        (lambda (proc owner thread kind mask)
          (new proc owner thread kind (box #f) 'queued #f #f '() mask #f #f #f '()
               #f #f #f #f #f #f #f 0 #f)))))

  (define-record-type thread-record
    (nongenerative)
    (sealed #t)
    (fields mutex condition)
    (protocol (lambda (new) (lambda () (new (make-mutex) (make-condition))))))

  ;; Held for a few field writes, never while waiting, so a spin with
  ;; interrupts disabled costs less than a mutex and lets no request land
  ;; half way.
  (define-syntax with-task-lock
    (syntax-rules ()
      [(_ t e1 e2 ...) (with-interrupts-disabled (holding-task-lock t e1 e2 ...))]))

  (define-syntax holding-task-lock
    (syntax-rules ()
      [(_ t e1 e2 ...)
       (let ([b (task-lock t)])
         (let spin () (unless (box-cas! b #f #t) (spin)))
         (memory-order-acquire)
         (let ([v (begin e1 e2 ...)])
           (memory-order-release)
           (set-box! b #f)
           v))]))

  (define (check-task who v)
    (unless (task? v) (assertion-violation who "not a task" v)))

  (define (task-state* t)
    (check-task 'task-state t)
    (let ([state (task-state t)])
      (if (eq? state 'paused)
          (with-task-lock t
            (let ([state (task-state t)] [r (task-resumed t)])
              (if (and (eq? state 'paused) (or (and r (eq? (car r) (task-pause t))) (pending-request? t)))
                  'woken
                  state)))
          state)))

  (define (task-owner* t)
    (check-task 'task-owner t)
    (task-owner t))

  (define (task-request t)
    (check-task 'task-request t)
    (with-task-lock t
      (cond
        [(eq? (task-state t) 'done) #f]
        [(task-stop? t) 'stop]
        [(task-cancel t) 'cancel]
        [else #f])))

  (define live-mutex (make-mutex))
  (define live (make-eq-hashtable))

  (define (register-live! t)
    (with-kernel-mutex live-mutex (hashtable-set! live t #t)))

  (define (live-tasks)
    (with-kernel-mutex live-mutex (vector->list (hashtable-keys live))))

  (define (current-task)
    (thread-state-task (this-thread)))

  (define (current-owner)
    (let ([s (this-thread)])
      (owner-acted-for s (thread-state-task s))))

  (define (owner-acted-for s t)
    (if t
        (let ([fs (task-frames t)])
          (if (null? fs) (task-owner t) (owner-frame-owner (car fs))))
        (let ([fs (thread-state-frames s)])
          (cond
            [(pair? fs) (owner-frame-owner (car fs))]
            [(thread-state-main? s) kernel-owner]
            [else #f]))))

  (define (masked-now? s)
    (let ([t (thread-state-task s)])
      (and t (fx> (task-mask t) 0))))

  (define (task-cleanup? t) (eq? (task-kind t) 'cleanup))

  (define (task-on-thread? t) (and (task-thread t) #t))

  ;; A task is live once made, so it is queued, forked or started before a
  ;; request can land: one landing in between would leave a task that
  ;; never runs, which an unload or exit then waits for.
  (define (new-task proc owner thread kind masked?)
    (let ([t (make-task proc owner thread kind (if masked? 1 0))])
      (register-live! t)
      t))

  ;;; The main loop

  (define queue-mutex (make-mutex))
  (define queue-ready (make-condition))
  (define queue-head '())
  (define queue-tail '())

  ;; Taking all the waiting items at once takes the mutex once per burst.
  (define taken '())

  ;; Only the main thread waits for the queue, so what it queues itself
  ;; wakes no one.
  (define (enqueue! item)
    (with-kernel-mutex queue-mutex
      (let ([cell (list item)])
        (if (null? queue-head)
            (set! queue-head cell)
            (set-cdr! queue-tail cell))
        (set! queue-tail cell))
      (unless (on-main-thread?) (condition-signal queue-ready))))

  (define (dequeue! wait?)
    (when (null? taken)
      (with-kernel-mutex queue-mutex
        (let loop ()
          (cond
            [(pair? queue-head)
             (set! taken queue-head)
             (set! queue-head '())]
            [wait? (condition-wait queue-ready queue-mutex) (loop)]))))
    (and (pair? taken)
         (let ([item (car taken)])
           (set! taken (cdr taken))
           item)))

  ;; Code leaving for the loop passes a thunk, since what follows, such as
  ;; finishing a task, must run outside the task's dynamic context.
  (define return-to-loop #f)

  ;; What a batch's items queue, and what batch-ended's advice queues, waits
  ;; for the next batch, so a flood of work is cut into batches. The task
  ;; that runs batch-ended is no batch of its own, or an idle loop would
  ;; never wait. It starts at once rather than queued, since another thread
  ;; may have queued work meanwhile, such as the resume of the task that
  ;; just paused.
  (define batch-ran? #f)

  ;; switching? is #t while a pause switches the task out or in, when its
  ;; winders must keep its frames, and ending while it unwinds to end,
  ;; when they must pop them; requests treat both alike.
  (define (switch-to-loop! t thunk)
    (when t (task-switching?-set! t #t))
    (return-to-loop thunk))

  (define (end-to-loop! t thunk)
    (when t (task-switching?-set! t 'ending))
    (return-to-loop thunk))

  (define (pausing? t) (eq? (task-switching? t) #t))

  ;; Most items return normally, so the loop takes its continuation once,
  ;; not per item. A raise no item handles reaches unhandled-raise, so the
  ;; loop runs under that handler alone.
  (define (run-items! wait?)
    (let ([outer-return return-to-loop] [outer-task (thread-state-task main-state)])
      (call-with-only-handler unhandled-raise
        (lambda ()
          ;; A task left by a stop, or by a raise that a module body's
          ;; handler saw, comes back with its handlers still current.
          (let* ([loop-state (current-exception-state)]
                 [after (call/cc (lambda (k) (set! return-to-loop k) void))])
            (current-exception-state loop-state)
            (let ([t (thread-state-task main-state)])
              (when t (task-switching?-set! t #f)))
            (thread-state-task-set! main-state #f)
            (after))
          (let loop ()
            (when (and exiting-task (eq? (task-state exiting-task) 'done))
              (exit-left!))
            (when (and exit-batch (eq? (task-state (car exit-batch)) 'done))
              (exit-batch-ended!))
            (when (and batch-ran? (null? taken))
              (set! batch-ran? #f)
              (unless (or unloading-for-exit? (eq? (wrapper-procedure-procedure batch-ended) do-nothing))
                (set! warned '())
                (start! (new-task (lambda (restore) (batch-ended)) kernel-owner #f 'kernel #f))))
            (let ([item (dequeue! wait?)])
              (when item
                (set! batch-ran? #t)
                (set! warned '())
                (if (task? item) (start! item) (item))
                (loop))))))
      (set! return-to-loop outer-return)
      (thread-state-task-set! main-state outer-task)))

  (define (run-main-loop)
    (timer-interrupt-handler timer-handler)
    (base-exception-handler unhandled-raise)
    (watch-signals!)
    (reset-handler
      (lambda ()
        (let ([t (thread-state-task main-state)])
          (end-to-loop! t (if t (lambda () (finish! t 'returned '())) void)))))
    (set-timer timer-ticks)
    (run-items! #t))

  (define (startable? t)
    (or (not (eq? (task-kind t) 'normal))
        (and (not unloading-for-exit?)
             (let ([o (task-owner t)])
               (or (eq? o kernel-owner) (eq? (owner-state o) 'loaded))))))

  (define (start! t)
    (when (eq? (task-state t) 'queued)
      (cond
        [(task-stop? t) (finish! t 'stopped #f)]
        [(task-cancel t) => (lambda (b) (finish! t 'cancelled (unbox b)))]
        [(not (startable? t)) (finish! t 'unstarted #f)]
        [else (run-main-task! t)])))

  (define (task-restore t)
    (lambda (thunk)
      (unless (procedure? thunk) (assertion-violation 'restore "not a procedure" thunk))
      (with-mask-depth t 0 thunk)))

  ;; A task that has paused runs on the stack it paused on, whose loop may
  ;; have returned, so it ends through the running loop.
  (define (run-main-task! t)
    (task-state-set! t 'running)
    (thread-state-task-set! main-state t)
    (let ([results (call-with-values (lambda () ((task-proc t) (task-restore t))) list)])
      (thread-state-task-set! main-state #f)
      (if (task-continuation t)
          (end-to-loop! t (lambda () (finish! t 'returned results)))
          (finish! t 'returned results))))

  (define (finish! t how detail)
    (let ([joiners (with-task-lock t
                     (task-state-set! t 'done)
                     (task-how-set! t how)
                     (task-detail-set! t detail)
                     (let ([js (task-joiners t)]) (task-joiners-set! t '()) js))])
      (task-continuation-set! t #f)
      (task-frames-set! t '())
      (unless (task-thread t)
        (drop-bodies-of! t)
        (forget-raised-in-body!))
      (with-kernel-mutex live-mutex (hashtable-delete! live t))
      (when (task-thread t)
        (let ([o (task-owner t)])
          (with-kernel-mutex threads-mutex (owner-threads-set! o (remq t (owner-threads o))))))
      (for-each (lambda (join) (join)) joiners)
      (unless (null? unload-waiters) (notify-unload-waiters!))))

  ;; A compile cannot pause, so a warning raised twice comes within one
  ;; item.
  (define warned '())

  ;; A raise is reported before the stack unwinds, so advice on report sees
  ;; where it was raised.
  (define (unhandled-raise c)
    (let* ([s (this-thread)] [t (thread-state-task s)])
      (cond
        [(warning-only? c)
         (if (thread-state-main? s)
             (set! warned (report-warning-once c warned))
             (report-from-thread c))]
        [(not (thread-state-main? s))
         (if t
             (thread-task-raised t c)
             (begin (report-from-thread c) (reset)))]
        [(not t) (report-safely c) (reset)]
        [(task-stopping? t) (task-ended! t 'stopped #f)]
        [(cancelled? c) (task-ended! t 'cancelled (cancelled-reason c))]
        [else
         (report-safely c)
         (task-ended! t 'raised c)])))

  (define exiting-task-leaving? #f)

  (define (task-ended! t how detail)
    (end-to-loop! t (lambda () (finish! t how detail))))

  ;;; Requests

  (define timer-ticks 1000)
  (define ticking? #f)

  (define (pending-request? t)
    (if (task-stop-deferred? t)
        (or (task-stop? t) (fx= (task-winding t) 0))
        (or (task-stop? t) (task-unloaded t) (task-cancel t))))

  ;; The main thread's handler also calls tick. A request lands only in a
  ;; task's own code, never in kernel bookkeeping or while the loop
  ;; switches the task out or in; a stop also lands while a stop unwinds
  ;; the task, skipping the winder it lands in. A request that finds
  ;; bookkeeping is looked at again at the next trap check, not a timer
  ;; period later: code that loops in step with the timer could meet
  ;; bookkeeping at every period.
  (define (timer-handler)
    (set-timer timer-ticks)
    (let* ([s (this-thread)] [t (thread-state-task s)])
      (when (and t (eq? (task-state t) 'running))
        (cond
          [(fx> (thread-state-kernel-depth s) 0)
           (when (or (task-stop? t) (task-unloaded t) (and (task-cancel t) (fx= (task-mask t) 0)))
             (set-timer 1))]
          [(task-switching? t)
           (when (and (task-stopping? t) (task-stop? t)) (stop-now! t))]
          [ticking? (when (task-stop? t) (land-stop! t))]
          [else
           (when (and (thread-state-main? s) (not (eq? (wrapper-procedure-procedure tick) do-nothing)))
             (fluid-let ([ticking? #t])
               (with-mask-depth t (fx+ (task-mask t) 1)
                 (lambda () (guard (c [(not (serious-condition? c)) (void)] [#t (report-safely c)]) (tick))))))
           (deliver-running! t)]))))

  (define (deliver-running! t)
    (cond
      [(task-stop? t) (land-stop! t)]
      [(task-stop-deferred? t) (when (fx= (task-winding t) 0) (stop-now! t))]
      [(task-unloaded t) (raise-unloaded-now! t)]
      [(and (task-cancel t) (fx= (task-mask t) 0)) (raise-cancel-now! t)]))

  (define (deliver-at-pause! t)
    (cond
      [(task-stop? t) (land-stop! t) 'none]
      [(task-stop-deferred? t) (if (fx= (task-winding t) 0) (stop-now! t) 'none)]
      [(task-unloaded t) (raise-unloaded-now! t)]
      [(task-cancel t) (raise-cancel-now! t)]
      [else 'none]))

  ;; Escaping from a winder's before or after thunk would skip the rest of
  ;; it, and a with-mutex would keep its mutex for ever, so a first stop
  ;; that lands in one starts the unwinding once the thunk has run; a
  ;; further stop skips it.
  (define (land-stop! t)
    (if (and (fx> (task-winding t) 0) (not (task-stopping? t)))
        (begin
          (with-task-lock t (task-stop?-set! t #f))
          (task-stopping?-set! t #t)
          (task-stop-deferred?-set! t #t))
        (stop-now! t)))

  (define (poll! t)
    (when (fx= (thread-state-kernel-depth (this-thread)) 0)
      (deliver-running! t)))

  (define (stop-now! t)
    (with-task-lock t (task-stop?-set! t #f))
    (task-stopping?-set! t #t)
    (task-stop-deferred?-set! t #f)
    (if (task-thread t)
        ((task-escape t) (list 'stopped #f))
        (end-to-loop! t (lambda () (finish! t 'stopped #f)))))

  (define (raise-cancel-now! t)
    (let ([reason (with-task-lock t
                    (let ([b (task-cancel t)]) (task-cancel-set! t #f) (and b (unbox b))))])
      (raise-continuable (make-cancelled reason))))

  ;; Raised under the exception state of the outermost frame of the
  ;; unloading code, so no handler inside that code catches it and it comes
  ;; out in the caller as an ordinary raise.
  (define (raise-unloaded-now! t)
    (let ([f (with-task-lock t
               (task-unloaded-set! t #f)
               (find (lambda (f) (not (eq? (owner-state (owner-frame-owner f)) 'loaded)))
                     (reverse (task-frames t))))])
      (when f
        (current-exception-state (owner-frame-exception-state f))
        (raise (unloaded-condition 'call-as-owner (owner-frame-owner f))))))

  (define (wake-for-request! t)
    (let* ([seen (with-task-lock t (list (task-state t) (task-pause t) (task-waiting-on t)))]
           [state (car seen)] [token (cadr seen)] [waiting (caddr seen)])
      (when (eq? state 'paused)
        (if (task-thread t)
            (signal-thread-task! t)
            (enqueue! (lambda () (continue! t token wake-marker)))))
      (when waiting (wake-condition! (car waiting) (cdr waiting)))))

  ;; The waiter holds the mutex between its check and its wait, so the
  ;; broadcast takes it; a waiter that holds it for long is woken from a
  ;; thread of its own rather than holding up the canceller.
  (define (wake-condition! c m)
    (if (mutex-acquire m #f)
        (begin (condition-broadcast c) (mutex-release m))
        (fork-thread (lambda () (with-mutex m (condition-broadcast c))))))

  (define cancel-task
    (case-lambda
      [(t) (cancel-task t #f)]
      [(t reason)
       (check-task 'cancel-task t)
       (when (with-task-lock t
               (and (not (eq? (task-state t) 'done))
                    (begin (unless (or (task-cancel t) (task-stop? t)) (task-cancel-set! t (box reason))) #t)))
         (wake-for-request! t))
       (void)]))

  (define (stop-task t)
    (check-task 'stop-task t)
    (when (with-task-lock t
            (and (not (eq? (task-state t) 'done))
                 (begin (task-stop?-set! t #t) (task-cancel-set! t #f) #t)))
      (wake-for-request! t))
    (void))

  ;;; Masks

  ;; Requests land only at Chez's trap checks, which come at the entry of a
  ;; procedure that makes a call (CSUG 12.2), so a winder that makes none
  ;; changes the depth in one step with its wind's push or pop. A critical
  ;; wind would too, but each time it enables interrupts it runs the
  ;; timer's event handler.
  ;;
  ;; A swap, as parameterize's winders do, so code left and re-entered by a
  ;; continuation gets back the depth it had.
  (define-syntax swap-mask!
    (syntax-rules ()
      [(_ t other) (let ([d (task-mask t)]) (task-mask-set! t other) (set! other d))]))

  (define (with-mask-depth t depth thunk)
    (let ([other depth])
      (dynamic-wind
        (lambda () (swap-mask! t other))
        (lambda ()
          (when (and (fx= (task-mask t) 0) (pending-request? t)) (poll! t))
          (thunk))
        (lambda () (swap-mask! t other)))))

  (define (call-with-cancellation-masked proc)
    (unless (procedure? proc)
      (assertion-violation 'call-with-cancellation-masked "not a procedure" proc))
    (let ([t (current-task)])
      (if t
          (let* ([outer (task-mask t)] [open? #f] [other (fx+ outer 1)]
                 [restore (lambda (thunk)
                            (unless (procedure? thunk) (assertion-violation 'restore "not a procedure" thunk))
                            (unless open? (assertion-violation 'restore "its mask has returned"))
                            (with-mask-depth t outer thunk))])
            (dynamic-wind
              (lambda () (swap-mask! t other) (set! open? #t))
              (lambda () (proc restore))
              (lambda () (set! open? #f) (swap-mask! t other))))
          (proc (lambda (thunk) (thunk))))))

  ;; Winders run masked, while in and out run with interrupts on, so they
  ;; may wait for a mutex and a collection may run.
  (define (tuna-dynamic-wind in body out)
    (let ([t (current-task)])
      (if t
          (let ()
            (define (mask!)
              (task-mask-set! t (fx+ (task-mask t) 1))
              (task-winding-set! t (fx+ (task-winding t) 1)))
            ;; Code that is mostly winders may be in one at every tick, so a
            ;; stop held off by one lands at the first tick out of it.
            (define (unmask!)
              (task-mask-set! t (fx- (task-mask t) 1))
              (task-winding-set! t (fx- (task-winding t) 1))
              (when (and (task-stop-deferred? t) (fx= (task-winding t) 0)) (set-timer 1)))
            (dynamic-wind #t mask!
              (lambda ()
                (dynamic-wind in
                  (lambda () (dynamic-wind unmask! body mask!))
                  (lambda () (call-after-thunk t out))))
              unmask!))
          (dynamic-wind in body out))))

  ;;; Pauses

  (define wake-marker (string->uninterned-symbol "wake"))

  (define (make-resume t token)
    (let ([used? #f] [used-mutex (make-mutex)])
      (lambda (thunk)
        (unless (procedure? thunk) (assertion-violation 'resume "not a procedure" thunk))
        (when (with-kernel-mutex used-mutex (let ([u used?]) (set! used? #t) u))
          (assertion-violation 'resume "the task was resumed already"))
        (if (task-thread t)
            (resume-thread-task! t token thunk)
            (begin
              (with-task-lock t
                (when (eq? (task-pause t) token)
                  (task-resumed-set! t (cons token thunk))))
              (enqueue! (lambda () (continue! t token thunk))))))))

  ;; A wake that delivers nothing pauses again at the same pause, where a
  ;; resume queued before it still continues the task.
  (define (continue! t token thunk)
    (when (with-task-lock t
            (and (eq? (task-state t) 'paused) (eq? (task-pause t) token)
                 (begin
                   (task-state-set! t 'running)
                   (unless (eq? thunk wake-marker) (task-resumed-set! t #f))
                   #t)))
      (task-switching?-set! t #t)
      (thread-state-task-set! main-state t)
      ((task-continuation t) thunk)))

  (define running-bodies '())

  (define (body-running)
    (and (pair? running-bodies) (running-body-name (car running-bodies))))

  (define (running-body-records) running-bodies)

  ;; The receiver runs in the task, before it pauses, so a resume it calls
  ;; at once is queued and taken once the task has paused. A request that
  ;; arrives while the task pauses keeps it from pausing.
  (define (suspend receiver)
    (unless (procedure? receiver) (assertion-violation 'suspend "not a procedure" receiver))
    (let* ([s (this-thread)] [t (thread-state-task s)])
      (unless t (assertion-violation 'suspend "not in a task"))
      (let ([body (and (thread-state-main? s) (body-running))])
        (when body (assertion-violationf 'suspend "the body of module ~s is running" body)))
      (let ([r (deliver-at-pause! t)])
        (if (not (eq? r 'none))
            r
            (let ([token (string->uninterned-symbol "pause")])
              (task-pause-set! t token)
              (receiver (make-resume t token))
              (let wait ()
                (let ([thunk (if (thread-state-main? s) (pause-main! t token) (pause-thread! t token))])
                  (if (eq? thunk wake-marker)
                      (let ([r (deliver-at-pause! t)])
                        (if (eq? r 'none)
                            (begin (task-pause-set! t token) (wait))
                            (begin (task-pause-set! t #f) r)))
                      (begin (task-pause-set! t #f) (thunk))))))))))

  (define (pause-main! t token)
    (let ([thunk (call/cc
                   (lambda (k)
                     (if (with-task-lock t
                           (and (not (pending-request? t))
                                (begin
                                  (task-continuation-set! t k)
                                  (task-state-set! t 'paused)
                                  #t)))
                         (switch-to-loop! t void)
                         wake-marker)))])
      (task-switching?-set! t #f)
      thunk))

  ;; The continuation is kept only so task-frames can read a paused
  ;; thread task's frames.
  (define (pause-thread! t token)
    (let ([th (task-thread t)])
      (call/cc
        (lambda (k)
          (task-continuation-set! t k)
          (let ([thunk (kernel-section (this-thread) (with-mutex (thread-record-mutex th)
                         (with-task-lock t (task-state-set! t 'paused))
                         (let wait ()
                           (let ([thunk (with-task-lock t
                                          (let ([r (task-resumed t)])
                                            (cond
                                              [(and r (eq? (car r) token)) (task-resumed-set! t #f) (cdr r)]
                                              [(pending-request? t) wake-marker]
                                              [else #f])))])
                             (cond
                               [thunk (with-task-lock t (task-state-set! t 'running)) thunk]
                               [else (condition-wait (thread-record-condition th) (thread-record-mutex th)) (wait)])))))])
            (task-continuation-set! t #f)
            thunk)))))

  (define (resume-thread-task! t token thunk)
    (let ([th (task-thread t)])
      (with-mutex (thread-record-mutex th)
        (with-task-lock t
          (when (eq? (task-pause t) token)
            (task-resumed-set! t (cons token thunk))))
        (condition-signal (thread-record-condition th)))))

  (define (signal-thread-task! t)
    (let ([th (task-thread t)])
      (with-mutex (thread-record-mutex th)
        (condition-signal (thread-record-condition th)))))

  (define (join-task t)
    (check-task 'join-task t)
    (when (eq? t (current-task))
      (assertion-violation 'join-task "a task cannot wait for itself" t))
    (unless (eq? (task-state t) 'done)
      (suspend
        (lambda (resume)
          (unless (with-task-lock t
                    (and (not (eq? (task-state t) 'done))
                         (begin (task-joiners-set! t (cons (lambda () (resume void)) (task-joiners t))) #t)))
            (resume void)))))
    ;; finish! sets the state before how and detail, so a join that read
    ;; done outside the lock reads them under it.
    (let ([end (with-task-lock t (cons (task-how t) (task-detail t)))])
      (values (car end) (cdr end))))

  ;; The waiter records the condition it waits on, so a request can wake
  ;; it; a pending request lands when it wakes, as at a pause.
  (define tuna-condition-wait
    (case-lambda
      [(c m) (tuna-condition-wait c m #f)]
      [(c m timeout)
       (let ([t (current-task)])
         (if (not t)
             (condition-wait c m timeout)
             (if (eq? (deliver-at-pause! t) 'none)
                 (begin
                   (with-task-lock t (task-waiting-on-set! t (cons c m)))
                   (let ([woken (or (and (pending-request? t) #t) (condition-wait c m timeout))])
                     (with-task-lock t (task-waiting-on-set! t #f))
                     (deliver-at-pause! t)
                     woken))
                 #t)))]))

  ;; The main thread would block every task.
  (define (tuna-sleep duration)
    (cond
      [(on-main-thread?)
       (assertion-violation 'sleep "would block the main thread; pause a task instead")]
      [(current-task)
       (let ([m (make-mutex)] [c (make-condition)]
             [deadline (add-duration (current-time 'time-monotonic) duration)])
         (with-mutex m
           (let wait ()
             (let ([left (time-difference deadline (current-time 'time-monotonic))])
               (when (time>? left (make-time 'time-duration 0 0))
                 (tuna-condition-wait c m left)
                 (wait))))))]
      [else (sleep duration)]))

  ;;; Threads that are tasks

  (define threads-mutex (make-mutex))

  (define (fork-task proc)
    (unless (procedure? proc) (assertion-violation 'fork-task "not a procedure" proc))
    (let* ([s (this-thread)] [owner (current-owner)])
      (unless owner (assertion-violation 'fork-task "this thread acts for no owner; name one with call-as-owner"))
      (unless (or (eq? owner kernel-owner) (eq? (owner-state owner) 'loaded))
        (raise (unloaded-condition 'fork-task owner)))
      (kernel-section s
        (let ([t (new-task proc owner (make-thread-record) 'normal (masked-now? s))])
          (with-kernel-mutex threads-mutex (owner-threads-set! owner (cons t (owner-threads owner))))
          (with-task-lock t (task-state-set! t 'running))
          (fork-thread (lambda () (run-thread-task! t)))
          t))))

  ;; A stop escapes to the thread's base; a further stop escapes again,
  ;; skipping the winder it lands in.
  (define (run-thread-task! t)
    (current-thread-state (make-thread-state (get-thread-id) #f t '() 0))
    (timer-interrupt-handler timer-handler)
    (set-timer timer-ticks)
    (let ([outcome (call/cc
                     (lambda (k)
                       (task-escape-set! t k)
                       (call-with-values
                         (lambda () ((task-proc t) (task-restore t)))
                         (lambda results (list 'returned results)))))])
      (set-timer 0)
      (finish! t (car outcome) (cadr outcome))))

  (define (thread-task-raised t c)
    (cond
      [(task-stopping? t) ((task-escape t) (list 'stopped #f))]
      [(cancelled? c) ((task-escape t) (list 'cancelled (cancelled-reason c)))]
      [else
       (report-from-thread c)
       ((task-escape t) (list 'raised c))]))

  ;; Advice on report may change state only the main thread may change, so
  ;; a raise on another thread is reported there, as the owner the raising
  ;; code acted for.
  (define (report-from-thread c)
    (spawn-task* (lambda (restore) (report-safely c)) (or (current-owner) kernel-owner) 'kernel #f))

  (define (owner-threads* o)
    (with-kernel-mutex threads-mutex (owner-threads o)))

  ;;; Owner frames

  (define-record-type owner-frame
    (nongenerative)
    (sealed #t)
    (fields owner exception-state))

  ;; A task's frames and its pending &unloaded change only on its own
  ;; thread and in an unload's scan, which on the main thread runs between
  ;; tasks, so only another thread's task takes its lock for them. The
  ;; winders that change them are critical, so interrupts are off already.
  (define-syntax with-frames-lock
    (syntax-rules ()
      [(_ s t e1 e2 ...)
       (if (thread-state-main? s)
           (begin e1 e2 ...)
           (holding-task-lock t e1 e2 ...))]))

  ;; The check and the push are one step against an unload's scan of the
  ;; task.
  (define (push-frame! s t frame)
    (with-frames-lock s t
      (and (eq? (owner-state (owner-frame-owner frame)) 'loaded)
           (begin (task-frames-set! t (cons frame (task-frames t))) #t))))

  (define (remove-frame frame fs)
    (if (and (pair? fs) (eq? (car fs) frame)) (cdr fs) (remq frame fs)))

  ;; Leaving the code withdraws a pending &unloaded.
  (define (pop-frame! s t frame)
    (with-frames-lock s t
      (task-frames-set! t (remove-frame frame (task-frames t)))
      (when (and (task-unloaded t)
                 (not (exists (lambda (f) (not (eq? (owner-state (owner-frame-owner f)) 'loaded)))
                              (task-frames t))))
        (task-unloaded-set! t #f)))
    (unless (eq? (owner-state (owner-frame-owner frame)) 'loaded)
      (notify-unload-waiters!)))

  (define (innermost? t frame)
    (let ([fs (task-frames t)])
      (and (pair? fs) (eq? (car fs) frame))))

  ;; Code entered as an owner: the frame is popped when the code is left by
  ;; a return, a raise or a jump, and kept while the loop switches the task
  ;; out at a pause and back in. A jump back into the code passes the check
  ;; again, and raises &unloaded once the owner's unload has begun.
  ;; refused runs, outside any frame, when that unload had begun at entry.
  ;; A task's winders here make calls, so they are critical: a request
  ;; landing between a wind's push or pop and the frame's would leave the
  ;; frame behind. Code outside a task gets no request.
  (define (call-entered-as owner thunk refused)
    (let* ([s (this-thread)] [t (thread-state-task s)])
      (enter-as s t owner (current-exception-state) thunk refused)))

  (define (enter-as s t owner state thunk refused)
    (if t
        (let ([frame (make-owner-frame owner state)] [entry 'new])
          (dynamic-wind #t
            (lambda ()
              (case entry
                [(new) (set! entry (if (push-frame! s t frame) 'in 'refused))]
                [(refused) (void)]
                [else
                 (unless (or (task-switching? t) (innermost? t frame) (push-frame! s t frame))
                   (current-exception-state state)
                   (raise (unloaded-condition 'call-as-owner owner)))]))
            (lambda () (if (eq? entry 'refused) (refused) (thunk)))
            (lambda ()
              (unless (or (eq? entry 'refused) (pausing? t))
                (pop-frame! s t frame)))))
        (if (or (eq? owner kernel-owner) (eq? (owner-state owner) 'loaded))
            (let ([outer (thread-state-frames s)])
              (dynamic-wind
                (lambda () (thread-state-frames-set! s (cons (make-owner-frame owner #f) outer)))
                thunk
                (lambda () (thread-state-frames-set! s outer))))
            (refused))))

  ;; Back in the code that called an advised procedure: its owner was
  ;; checked when that code was entered, so the frame goes on unchecked;
  ;; state is that code's exception state, under which &unloaded comes out.
  (define (call-as-caller owner state thunk)
    (let* ([s (this-thread)] [t (thread-state-task s)])
      (if t
          (let ([frame (make-owner-frame owner state)] [in? #f])
            (dynamic-wind #t
              (lambda ()
                (unless (and in? (or (task-switching? t) (innermost? t frame)))
                  (with-frames-lock s t (task-frames-set! t (cons frame (task-frames t)))))
                (set! in? #t))
              thunk
              (lambda ()
                (unless (pausing? t)
                  (pop-frame! s t frame)))))
          (let ([outer (thread-state-frames s)])
            (dynamic-wind
              (lambda () (thread-state-frames-set! s (cons (make-owner-frame owner #f) outer)))
              thunk
              (lambda () (thread-state-frames-set! s outer)))))))

  (define (call-as-owner owner thunk)
    (unless (owner? owner) (assertion-violation 'call-as-owner "not an owner" owner))
    (unless (procedure? thunk) (assertion-violation 'call-as-owner "not a procedure" thunk))
    (call-entered-as owner thunk (lambda () (raise (unloaded-condition 'call-as-owner owner)))))

  (define (task-in-code-of? t o)
    (exists (lambda (f) (eq? (owner-frame-owner f) o)) (task-frames t)))

  ;; A module's body runs in the loading task as its instance. Its code is
  ;; Chez's library body, which no winder can wrap, so a body left without
  ;; reaching its end is dropped by whoever sees it go: its own exception
  ;; handler for a raise, finish! for a task that ended inside it. drop
  ;; unloads the instance.
  (define-record-type running-body
    (nongenerative)
    (sealed #t)
    (fields name instance task frame outer-state drop))

  ;; The body's handler is the last its own code reaches, so it sees only a
  ;; raise that leaves the body; &unloaded for the instance is raised under
  ;; it too.
  (define (begin-body! instance name drop)
    (let* ([t (thread-state-task main-state)]
           [outer-state (current-exception-state)]
           [b #f]
           [state (with-exception-handler (lambda (c) (body-raised b c)) current-exception-state)]
           [frame (make-owner-frame instance state)])
      (set! b (make-running-body name instance t frame outer-state drop))
      (kernel-section main-state
        (set! running-bodies (cons b running-bodies))
        (if t
            (with-task-lock t (task-frames-set! t (cons frame (task-frames t))))
            (thread-state-frames-set! main-state (cons frame (thread-state-frames main-state)))))
      (current-exception-state state)
      b))

  ;; Chez's invoke unwinds out of a failed body before it raises again,
  ;; so the body's frame is gone when the raise is reported. The body
  ;; notes the instance it was raised in, the innermost first, until the
  ;; load that ran it is left; a handler may report the raise with more
  ;; conditions added.
  (define raised-in-body (make-thread-parameter #f))

  ;; Setting a thread parameter takes Chez's global thread mutex, and every
  ;; task's end forgets.
  (define (forget-raised-in-body!)
    (when (raised-in-body) (raised-in-body #f)))

  (define (raised-in c)
    (let ([r (raised-in-body)])
      (and r
           (let ([parts (lambda (x) (if (condition? x) (simple-conditions x) (list x)))])
             (exists (lambda (part) (memq part (parts c))) (parts (car r))))
           (cdr r))))

  (define (body-raised b c)
    (cond
      [(and (not (warning-only? c)) (body-live? b))
       (drop-body! b)
       (unless (raised-in c) (raised-in-body (cons c (running-body-instance b))))
       (raise c)]
      [else (raise-continuable c)]))

  (define (finish-body! b)
    (end-body! b)
    (current-exception-state (running-body-outer-state b)))

  (define (body-live? b) (and (memq b running-bodies) #t))

  (define (end-body! b)
    (let ([t (running-body-task b)] [frame (running-body-frame b)])
      (kernel-section main-state
        (set! running-bodies (remq b running-bodies))
        (if t
            (with-task-lock t (task-frames-set! t (remove-frame frame (task-frames t))))
            (thread-state-frames-set! main-state (remove-frame frame (thread-state-frames main-state)))))))

  ;; Requests wait, so a stop cannot leave the body ended and its instance
  ;; loaded.
  (define (drop-body! b)
    (kernel-section main-state
      (when (body-live? b)
        (end-body! b)
        ((running-body-drop b) (running-body-instance b)))))

  (define (drop-bodies-of! t)
    (for-each (lambda (b) (when (eq? (running-body-task b) t) (drop-body! b))) running-bodies))

  ;; Step 1 of an unload: every task inside the owner's code gets
  ;; &unloaded. The owner is marked unloading before any task's lock is
  ;; taken, so an entry after the scan of its task finds it.
  (define (mark-unloading-code! o)
    (for-each
      (lambda (t)
        (when (with-task-lock t
                (and (not (eq? (task-state t) 'done))
                     (task-in-code-of? t o)
                     (begin (unless (task-unloaded t) (task-unloaded-set! t o)) #t)))
          (wake-for-request! t)))
      (live-tasks)))

  (define waiters-mutex (make-mutex))
  (define unload-waiters '())

  (define (add-unload-waiter! resume)
    (with-kernel-mutex waiters-mutex (set! unload-waiters (cons resume unload-waiters))))

  (define (notify-unload-waiters!)
    (let ([ws (with-kernel-mutex waiters-mutex (let ([ws unload-waiters]) (set! unload-waiters '()) ws))])
      (for-each (lambda (resume) (resume void)) ws)))

  ;;; Spawning

  (define (spawn-task* proc owner kind masked?)
    (kernel-section (this-thread)
      (let ([t (new-task proc owner #f kind masked?)])
        (enqueue! t)
        t)))

  (define (spawn-task proc)
    (unless (procedure? proc) (assertion-violation 'spawn-task "not a procedure" proc))
    (let* ([s (this-thread)] [owner (current-owner)])
      (unless owner (assertion-violation 'spawn-task "this thread acts for no owner; name one with call-as-owner"))
      (spawn-task* proc owner 'normal (masked-now? s))))

  (define (spawn-kernel-task proc)
    (spawn-task* proc kernel-owner 'kernel #f))

  (define (spawn-cleanup-task owner proc)
    (spawn-task* proc owner 'cleanup #f))

  ;;; Frames of a paused task, as data

  (define (task-frames* t)
    (check-task 'task-frames t)
    (case (task-state t)
      [(done) '()]
      [(running) #f]
      [(queued) '()]
      [else
       (let ([k (task-continuation t)])
         (if k
             (let loop ([o (inspect/object k)] [frames '()])
               (if (and o (eq? (o 'type) 'continuation))
                   (let* ([code (o 'code)]
                          [name (and code (code 'name))]
                          [source (let ([s (o 'source-object)]) (if (procedure? s) (s 'value) s))]
                          [frames (cons (cons name source) frames)])
                     (if (fx> (o 'depth) 1) (loop (o 'link) frames) (reverse frames)))
                   (reverse frames)))
             '()))]))

  ;;; Exit

  (define leaving-to-exit #f)
  (define exiting-task #f)
  (define raised-leaving '())
  (define unloading-for-exit? #f)
  (define exit-runner (lambda (arguments) (apply chez:exit arguments)))

  (define (set-exit-runner! runner) (set! exit-runner runner))

  (define (begin-exit-unloading!) (set! unloading-for-exit? #t))

  (define (exit-unloading?) unloading-for-exit?)

  (define (exit . arguments)
    (let* ([s (this-thread)] [t (thread-state-task s)])
      (cond
        [(not (thread-state-main? s))
         (enqueue! (lambda () (apply exit arguments)))
         (when t ((task-escape t) (list 'returned '())))]
        [unloading-for-exit?
         (when t (task-ended! t 'returned '()))]
        [t
         (unless leaving-to-exit
           (set! leaving-to-exit arguments)
           (set! exiting-task t)
           (set! exiting-task-leaving? #t))
         (task-ended! t 'returned '())]
        [else (start-exit! arguments '())])))

  (define (exit-left!)
    (let ([arguments leaving-to-exit] [raised (reverse raised-leaving)])
      (set! leaving-to-exit #f)
      (set! exiting-task #f)
      (set! exiting-task-leaving? #f)
      (set! raised-leaving '())
      (start-exit! arguments raised)))

  ;; exit-anyway? is asked in a task, so that its advice can wait for the
  ;; user's answer. Then the batch exit was called in ends before anything
  ;; stops or unloads, so batch-ended's advice sees what the batch changed.
  ;; The loop, not that task, goes on with the exit once the task has ended,
  ;; so a cancel or a stop that ends it cannot drop the exit.
  (define exit-batch #f)

  (define (start-exit! arguments raised)
    (cond
      [unloading-for-exit? (void)]
      [exit-batch (stop-task (car exit-batch))]
      [(null? raised)
       (set! batch-ran? #f)
       (let ([t (new-task end-exiting-batch kernel-owner #f 'kernel #f)])
         (set! exit-batch (cons t arguments))
         (start! t))]
      [else
       (spawn-kernel-task
         (lambda (restore)
           (when (and (for-all (lambda (c) (exit-anyway? c)) raised)
                      (not (or unloading-for-exit? exit-batch)))
             (set! exit-batch (cons (spawn-kernel-task end-exiting-batch) arguments)))))]))

  (define (end-exiting-batch restore) (batch-ended))

  (define (exit-batch-ended!)
    (let ([arguments (cdr exit-batch)])
      (set! exit-batch #f)
      (exit-runner arguments)))

  ;; While a stop or exit unwinds a task, each winder's raise is taken
  ;; where it happens, as Emacs catches the error of each kill-emacs-hook
  ;; function, and the unwinding goes on: no handler of the task may catch
  ;; it and carry on. A cancel is no fault, so it is not reported, but one
  ;; that cut a winder of the exiting task still makes exit ask.
  (define (call-after-thunk t out)
    (if (or (task-stopping? t) (and exiting-task-leaving? (eq? t exiting-task)))
        (call/cc
          (lambda (k)
            (call-with-only-handler
              (lambda (c)
                (cond
                  [(warning-only? c) (set! warned (report-warning-once c warned))]
                  [else
                   (unless (cancelled? c) (report-safely c))
                   (when (eq? t exiting-task) (set! raised-leaving (cons c raised-leaving)))
                   (k (void))]))
              out)))
        (out)))

  (define (stop-main-tasks!)
    (for-each
      (lambda (t)
        (unless (or (task-thread t) (not (eq? (task-kind t) 'normal)) (eq? (task-state t) 'done))
          (stop-task t)))
      (live-tasks)))

  (define (finish-exit! arguments)
    (fresh-line (current-output-port))
    (flush-output-port (current-output-port))
    (apply chez:exit arguments))

  (define running-cleanup #f)

  (define (stop-running-cleanup! t) (set! running-cleanup t))

  (define (take-signal! sig)
    ((foreign-procedure "tuna_take_signal" (int) int) sig))

  ;; A blocked foreign call would hold up every thread at the next
  ;; collection, so the wait lets collections run. Once exit is under way
  ;; the thread answers SIGINT itself, since what holds the exit up may
  ;; hold the main thread and the loop for ever. A thread that ended on a
  ;; raise would lose every later signal, Ctrl-C included.
  (define (watch-signals!)
    (let ([wait-signal (foreign-procedure __collect_safe "tuna_wait_signal" () int)])
      (fork-thread
        (lambda ()
          (let loop ()
            (let ([sig (wait-signal)])
              (when (fx> sig 0)
                (guard (c [#t (report-from-thread c)])
                  (unless (and (fx= sig 2) (interrupt-exit!))
                    (enqueue! (lambda () (handle-signal! sig)))))
                (loop))))))
      (take-signal! 2)))

  ;; A further stop skips the winder a first stop left running.
  (define (interrupt-exit!)
    (cond
      [unloading-for-exit?
       (let ([t running-cleanup]) (when t (stop-task t)))
       (for-each stop-task (filter task-stopping? (live-tasks)))
       #t]
      [exit-batch => (lambda (b) (stop-task (car b)) #t)]
      [else #f]))

  ;; Each signal's registrations, newest first, so a take-back gives the
  ;; signal back to the registration it replaced. Tuna's handler stays
  ;; installed once a signal is first registered, so the signal keeps its
  ;; key, and a signal no registration takes is ignored.
  (define signal-handlers (make-eqv-hashtable))

  (define (handle-signal! sig)
    (cond
      [(and (fx= sig 2) (interrupt-exit!)) (void)]
      [(find (lambda (entry) (eq? (owner-state (car entry)) 'loaded)) (hashtable-ref signal-handlers sig '()))
       => (lambda (entry) (spawn-task* (lambda (restore) ((cdr entry) sig)) (car entry) 'normal #f))]
      [(fx= sig 2) (exit)]))

  (define (tuna-register-signal-handler sig handler)
    (unless (fixnum? sig) (assertion-violation 'register-signal-handler "not a signal number" sig))
    (unless (procedure? handler) (assertion-violation 'register-signal-handler "not a procedure" handler))
    (check-main-thread 'register-signal-handler)
    (let* ([owner (changing-owner 'register-signal-handler)] [entry (cons owner handler)])
      (kernel-section (this-thread)
        (unless (or (fx= sig 2) (hashtable-contains? signal-handlers sig))
          (take-signal! sig))
        (hashtable-set! signal-handlers sig
          (cons entry (remp (lambda (e) (eq? (car e) owner)) (hashtable-ref signal-handlers sig '()))))
        (record-change! owner 'signal-handler sig #f
          (lambda () (hashtable-set! signal-handlers sig (remq entry (hashtable-ref signal-handlers sig '()))))))
      (void)))

  ;;; Changeable definitions

  ;; The value a name exports is one wrapper procedure, made at its first
  ;; definition and kept for the life of the process, so a value held
  ;; elsewhere follows every change. definer: the instance whose definition
  ;; is the base, or the last one once it unloaded.
  (define-record-type definition
    (nongenerative)
    (sealed #t)
    (fields symbol (mutable definer) (mutable procedure) (mutable doc) (mutable layers) gate)
    (protocol
      (lambda (new)
        (lambda (symbol gate) (new symbol #f #f #f '() gate)))))

  (define-record-type layer
    (nongenerative)
    (sealed #t)
    (fields owner kind holder sequence change))

  (define (layer-procedure l)
    (if (eq? (layer-kind l) 'advice-removal) (car (layer-holder l)) (layer-holder l)))

  (define definitions (make-eq-hashtable))
  (define next-sequence 0)

  (define (changeable? v)
    (and (wrapper-procedure? v) (definition? (wrapper-procedure-data v))))

  (define (definition-of who v)
    (unless (changeable? v)
      (assertion-violation who "not a changeable procedure" v))
    (wrapper-procedure-data v))

  (define (definition-symbol-of v) (definition-symbol (definition-of 'definition-symbol v)))

  (define (changeable-definer v) (definition-definer (definition-of 'changeable-definer v)))

  (define (definition-wrapper symbol) (hashtable-ref definitions symbol #f))

  (define (base-procedure d)
    (or (definition-procedure d)
        (lambda arguments
          (let* ([o (definition-definer d)]
                 [latest (hashtable-ref latest-module-instances (owner-name o) o)])
            (raise (condition (make-unloaded o) (make-who-condition (definition-symbol d))
                     (make-message-condition
                       (format (if (eq? (owner-state latest) 'loaded) "module ~s no longer defines it" "module ~s is unloaded")
                               (owner-name o)))))))))

  (define (live-layer? l)
    (let ([o (layer-owner l)])
      (and (eq? (owner-state o) 'loaded)
           (not (and (eq? (layer-kind l) 'advice-removal) (bwp-object? (car (layer-holder l))))))))

  (define (layer<? a b)
    (let ([ra (owner-rank (layer-owner a))] [rb (owner-rank (layer-owner b))])
      (or (< ra rb) (and (= ra rb) (fx< (layer-sequence a) (layer-sequence b))))))

  ;; One argument is the common case, so the layers' procedures make no
  ;; list for it.
  (define (enter-override l inner)
    (let ([owner (layer-owner l)] [p (layer-holder l)])
      (case-lambda
        [(a) (call-entered-as owner (lambda () (p a)) (lambda () (inner a)))]
        [arguments
         (call-entered-as owner
           (lambda () (apply p arguments))
           (lambda () (apply inner arguments)))])))

  ;; The advice runs as its owner and its next as the code that called the
  ;; procedure, so the layers below and the definition never take the
  ;; advice's owner for their caller's.
  (define (enter-advice l inner)
    (let ([owner (layer-owner l)] [p (layer-holder l)])
      (define (next-as-caller caller state)
        (case-lambda
          [(x) (call-as-caller caller state (lambda () (inner x)))]
          [arguments (call-as-caller caller state (lambda () (apply inner arguments)))]))
      (case-lambda
        [(a)
         (let* ([s (this-thread)] [t (thread-state-task s)] [caller (owner-acted-for s t)]
                [state (current-exception-state)])
           (enter-as s t owner state
             (lambda () (p (next-as-caller caller state) a))
             (lambda () (inner a))))]
        [arguments
         (let* ([s (this-thread)] [t (thread-state-task s)] [caller (owner-acted-for s t)]
                [state (current-exception-state)])
           (enter-as s t owner state
             (lambda () (apply p (next-as-caller caller state) arguments))
             (lambda () (apply inner arguments))))])))

  (define (base-caller d)
    (case-lambda
      [(a) ((base-procedure d) a)]
      [arguments (apply (base-procedure d) arguments)]))

  ;; The callee: the definition, or the highest-ranked override (the
  ;; definition when that is a removal), under the advice no removal hides,
  ;; the highest outermost. Under layers the base is read when called, so a
  ;; next in flight never runs an unloaded instance's definition.
  (define (retarget! w)
    (let* ([d (wrapper-procedure-data w)]
           [layers (filter live-layer? (definition-layers d))]
           [overrides (filter (lambda (l) (memq (layer-kind l) '(override override-removal))) layers)]
           [top (and (pair? overrides)
                     (fold-left (lambda (best l) (if (layer<? best l) l best)) (car overrides) (cdr overrides)))]
           [removals (filter (lambda (l) (eq? (layer-kind l) 'advice-removal)) layers)]
           [advice (list-sort layer<?
                     (filter (lambda (l)
                               (and (eq? (layer-kind l) 'advice)
                                    (not (exists (lambda (r)
                                                   (and (eq? (car (layer-holder r)) (layer-holder l))
                                                        (owner<? (layer-owner l) (layer-owner r))))
                                                 removals))))
                             layers))]
           [override (and top (eq? (layer-kind top) 'override) top)]
           [chain (if (and (not override) (null? advice))
                      (base-procedure d)
                      (fold-left (lambda (inner l) (enter-advice l inner))
                        (if override
                            (enter-override override (base-caller d))
                            (base-caller d))
                        advice))])
      (set-wrapper-procedure-procedure! w (if (definition-gate d) ((definition-gate d) chain) chain))))

  (define (retarget-changed! o)
    (for-each
      (lambda (c) (when (memq (change-kind c) '(advice override removal)) (retarget! (change-thing c))))
      (owner-changes o)))

  ;; Chez names a procedure after the variable it is first bound to, so the
  ;; wrapper's own name is the definition's symbol, for errors and samples.
  (define (new-wrapper symbol gate)
    (let ([w (make-wrapper-procedure void -1 (make-definition symbol gate))])
      (hashtable-set! definitions symbol w)
      w))

  ;; Mask -1: an arity-checking wrapper would refuse calls after a
  ;; redefinition that changes the arity.
  (define (define-changeable! owner symbol procedure doc)
    (kernel-section (this-thread) (define-changeable* owner symbol procedure doc)))

  (define (define-changeable* owner symbol procedure doc)
    (let* ([w (or (hashtable-ref definitions symbol #f) (new-wrapper symbol #f))]
           [d (wrapper-procedure-data w)])
      (unless (eq? (definition-definer d) owner)
        (record-change! owner 'define w symbol
          (lambda ()
            (when (eq? (definition-definer d) owner)
              (definition-procedure-set! d #f)
              (retarget! w)))))
      (definition-definer-set! d owner)
      (definition-procedure-set! d procedure)
      (definition-doc-set! d doc)
      (retarget! w)
      w))

  (define (kernel-define! symbol procedure gate)
    (let* ([w (new-wrapper symbol gate)] [d (wrapper-procedure-data w)])
      (definition-definer-set! d kernel-owner)
      (definition-procedure-set! d procedure)
      (retarget! w)
      w))

  (define (set-definition-documentation! w doc)
    (definition-doc-set! (wrapper-procedure-data w) doc))

  ;; A layer leaves with its owner's change, which an unload takes back.
  (define (add-layer! who w kind holder detail)
    (check-main-thread who)
    (let* ([owner (changing-owner who)] [d (wrapper-procedure-data w)])
      (set! next-sequence (fx+ next-sequence 1))
      (letrec* ([change (record-change! owner (if (memq kind '(advice-removal override-removal)) 'removal kind)
                          w detail (lambda () (drop-layer! d l)))]
                [l (make-layer owner kind holder next-sequence change)])
        (definition-layers-set! d (cons l (definition-layers d)))
        (retarget! w))))

  (define (drop-layer! d l)
    (definition-layers-set! d (remq l (definition-layers d))))

  (define (drop-own! owner d matching?)
    (for-each
      (lambda (l)
        (when (and (eq? (layer-owner l) owner) (matching? l))
          (forget-change! owner (layer-change l))
          (drop-layer! d l)))
      (definition-layers d)))

  (define (same-advice? advice)
    (lambda (l)
      (and (memq (layer-kind l) '(advice advice-removal)) (eq? (layer-procedure l) advice))))

  (define (advice-add! p advice)
    (let ([d (definition-of 'advice-add! p)])
      (unless (procedure? advice) (assertion-violation 'advice-add! "not a procedure" advice))
      (let ([owner (changing-owner 'advice-add!)])
        (check-main-thread 'advice-add!)
        (kernel-section (this-thread)
        (unless (exists (lambda (l) (and (eq? (layer-owner l) owner) (eq? (layer-kind l) 'advice)
                                         (eq? (layer-holder l) advice)))
                        (definition-layers d))
          (drop-own! owner d (same-advice? advice))
          (add-layer! 'advice-add! p 'advice advice advice))))))

  (define (advice-remove! p advice)
    (let ([d (definition-of 'advice-remove! p)])
      (unless (procedure? advice) (assertion-violation 'advice-remove! "not a procedure" advice))
      (let ([owner (changing-owner 'advice-remove!)])
        (check-main-thread 'advice-remove!)
        (kernel-section (this-thread)
          (drop-own! owner d (same-advice? advice))
          (let ([holder (weak-cons advice #f)])
            (add-layer! 'advice-remove! p 'advice-removal holder holder))))))

  (define (override-layer? l) (memq (layer-kind l) '(override override-removal)))

  (define (override-set! p replacement)
    (let ([d (definition-of 'override-set! p)])
      (unless (procedure? replacement) (assertion-violation 'override-set! "not a procedure" replacement))
      (let ([owner (changing-owner 'override-set!)])
        (check-main-thread 'override-set!)
        (kernel-section (this-thread)
          (drop-own! owner d override-layer?)
          (add-layer! 'override-set! p 'override replacement #f)))))

  (define (override-remove! p)
    (let ([d (definition-of 'override-remove! p)])
      (let ([owner (changing-owner 'override-remove!)])
        (check-main-thread 'override-remove!)
        (kernel-section (this-thread)
          (drop-own! owner d override-layer?)
          (add-layer! 'override-remove! p 'override-removal #f #f)))))

  (define (definition-changes p)
    (let* ([d (definition-of 'definition-changes p)] [definer (definition-definer d)])
      (append
        (map (lambda (l)
               (list (layer-owner l)
                     (case (layer-kind l)
                       [(advice-removal override-removal) 'removal]
                       [else (layer-kind l)])
                     (and (memq (layer-kind l) '(advice advice-removal)) (layer-procedure l))))
             (list-sort (lambda (a b) (fx> (layer-sequence a) (layer-sequence b)))
                        (filter live-layer? (definition-layers d))))
        (if definer (list (list definer 'define #f)) '()))))

  (define (definition-documentation p)
    (definition-doc (definition-of 'definition-documentation p)))

  (define (take-back-definitions! o)
    (for-each (lambda (c) ((change-undo c))) (owner-changes o))
    (owner-changes-set! o '()))

  ;;; The kernel's own changeable procedures

  (define (do-nothing) (void))

  ;; A report names the owner the raising code acted for, which advice on
  ;; report, entered as its own owner, would otherwise stand in for.
  (define reporting-owner (make-thread-parameter #f))

  (define (write-report c)
    (let ([o (or (reporting-owner) (current-owner))])
      (write-condition c (and o (eq? (owner-kind o) 'module) (owner-name o)))))

  (define (report-owner) (reporting-owner))

  (define (as-reported chain)
    (lambda (c)
      (parameterize ([reporting-owner (or (raised-in c) (current-owner))])
        (chain c))))

  (define report (kernel-define! 'report write-report as-reported))
  (define tick (kernel-define! 'tick do-nothing #f))
  (define batch-ended (kernel-define! 'batch-ended do-nothing #f))
  (define module-loaded (kernel-define! 'module-loaded (lambda (instance) (void)) #f))
  (define owner-unloading (kernel-define! 'owner-unloading (lambda (owner) (void)) #f))
  (define exit-anyway? (kernel-define! 'exit-anyway? (lambda (c) #t) #f))

  ;; A cancel that lands in report's advice is the task's, not a failure
  ;; to report.
  (define (report-safely c)
    (guard (e [(not (cancelled? e)) (write-report c) (write-report e)])
      (report c)))

  (define (report-warning who text)
    (report-safely (condition (make-warning) (make-who-condition who) (make-message-condition text))))

  ;; Chez runs its source optimizer twice, so one compile warning can be
  ;; raised twice; a warning whose text was reported already is not
  ;; reported again.
  (define (report-warning-once c reported)
    (let ([text (condition-text c)])
      (if (member text reported)
          reported
          (begin (report-safely c) (cons text reported)))))

  ;; A raise is reported in its own dynamic context, before anything
  ;; unwinds, so that advice on report can inspect it there.
  (define (call-reporting thunk)
    (call/cc
      (lambda (k)
        (with-exception-handler
          (lambda (c)
            (cond
              [(warning-only? c) (set! warned (report-warning-once c warned))]
              [(cancelled? c) (raise-continuable c)]
              [else (report-safely c) (k (void))]))
          thunk))))

  (record-writer (record-type-descriptor task)
    (lambda (t p wr) (display "#<task>" p)))

  (record-writer (record-type-descriptor owner)
    (lambda (o p wr) (format p "#<owner ~s ~a>" (owner-name o) (owner-number o))))
)
