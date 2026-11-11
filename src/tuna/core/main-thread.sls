(library (tuna core main-thread)
  (export
    post!
    post-task!
    request-quit!
    report-on-main-thread
    &quit
    make-quit-condition
    quit-condition?
    spawn-task
    suspend
    current-task
    task-done?
    join-task
    signal-task
    task?
    exit
    run-main-loop
    close-queue!
    run-queued!)
  (import (except (chezscheme) exit) (prefix (only (chezscheme) exit) chez:)
          (tuna core changes) (tuna core definitions) (tuna core conditions)
          (only (tuna core modules) running-module-body add-module-unloaded-handler!))

  (define-condition-type &quit &serious make-quit-condition quit-condition?)

  (define-record-type task
    (nongenerative)
    (sealed #t)
    (fields thunk owner instance
            (mutable state)
            (mutable continuation)
            (mutable result)
            (mutable finishers)
            (mutable signal)
            (mutable change))
    (protocol
      (lambda (new)
        (lambda (thunk owner finishers)
          (new thunk owner (current-instance owner) 'waiting #f #f finishers #f #f)))))

  (define queue-mutex (make-mutex))
  (define queue-ready (make-condition))
  (define queue-head '())
  (define queue-tail '())
  (define queue-closed? #f)

  ;; Taking all the waiting items at once takes the mutex once per burst,
  ;; not per item.
  (define taken '())

  (define (enqueue! item)
    (with-quit-safe-mutex queue-mutex
      (unless (and queue-closed? (not (on-main-thread?)))
        (let ([cell (list item)])
          (if (null? queue-head)
              (set! queue-head cell)
              (set-cdr! queue-tail cell))
          (set! queue-tail cell))
        (condition-signal queue-ready))))

  ;; Once the process is shutting down, what other threads post, such as
  ;; the console's next form or a second exit, would run after the modules
  ;; it uses are gone; only what the main thread queues while it unloads
  ;; runs.
  (define (close-queue!)
    (with-quit-safe-mutex queue-mutex
      (set! queue-closed? #t)
      (set! queue-head '())
      (set! taken '())))

  (define (dequeue! wait?)
    (when (null? taken)
      (with-quit-safe-mutex queue-mutex
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

  (define running-task #f)

  ;; Code leaving for the loop passes a thunk, since what follows, such as
  ;; finishing a task, must run outside the task's dynamic context.
  (define return-to-loop #f)

  (define (current-task)
    (and (on-main-thread?) running-task))

  ;; Most items return normally, so the loop takes its continuation once,
  ;; not per item, and a task sets its owner and quits-allowed without a
  ;; wind: it leaves only by returning or through return-to-loop, which
  ;; puts back the loop's. A raise no item handles reaches unhandled-raise,
  ;; so no item installs a handler of its own; the loop runs under it
  ;; alone, since the exit handler runs queued items inside whatever
  ;; handlers its caller set.
  (define (run-items! wait?)
    (let* ([outer-return return-to-loop] [outer-task running-task]
           [s (this-thread-state)] [loop-owner (thread-state-owner s)]
           [loop-allowed (thread-state-quits-allowed s)])
      (call-with-only-handler unhandled-raise
        (lambda ()
          (let ([after (call/cc (lambda (k) (set! return-to-loop k) void))])
            (thread-state-owner-set! s loop-owner)
            (thread-state-quits-allowed-set! s loop-allowed)
            (set! running-task #f)
            (after))
          (let loop ()
            (let ([item (dequeue! wait?)])
              (when item
                (clear-quit-requests!)
                (set! warned '())
                (if (task? item) (start! item) (item))
                (loop))))))
      (set! return-to-loop outer-return)
      (set! running-task outer-task)
      (clear-quit-requests!)))

  (define (finish! t state result)
    (task-state-set! t state)
    (task-result-set! t result)
    (task-continuation-set! t #f)
    (let ([change (task-change t)])
      (when change (forget-change! change)))
    (let ([finishers (task-finishers t)])
      (task-finishers-set! t '())
      (for-each (lambda (finish) (finish)) finishers)))

  ;; A task that has paused runs on the stack it paused on, whose loop may
  ;; have returned, so it ends through the running loop.
  (define (run-task-body t)
    (let* ([s (this-thread-state)] [outer-owner (thread-state-owner s)]
           [outer-allowed (thread-state-quits-allowed s)])
      (enter-task! s t)
      (let ([results (call-with-values (task-thunk t) list)])
        (thread-state-quits-allowed-set! s outer-allowed)
        (thread-state-owner-set! s outer-owner)
        (set! running-task #f)
        (if (task-continuation t)
            (return-to-loop (lambda () (finish! t 'done results)))
            (finish! t 'done results)))))

  (define (enter-task! s t)
    (thread-state-owner-set! s (task-owner t))
    (thread-state-quits-allowed-set! s #t)
    (set! running-task t))

  ;; Chez runs its source optimizer twice, so one compile warning can be
  ;; raised twice; an item reports each text once. A compile cannot pause,
  ;; so the twice-raised warnings come within one item.
  (define warned '())

  ;; A raise is reported before the stack unwinds, so advice on report and
  ;; Chez's debugger see where it was raised.
  (define (task-raised t c)
    (cond
      [(warning-only? c)
       (let ([text (condition-text c)])
         (unless (member text warned)
           (set! warned (cons text warned))
           (report-safely c)))]
      [else
       (report-safely c)
       (when (debug-on-exception)
         (debug-condition c)
         (debug))
       (return-to-loop (lambda () (finish! t 'failed c)))]))

  ;; Work posted by an instance of a module that has since unloaded must not
  ;; run under the module's next instance.
  (define (start! t)
    (when (eq? (task-state t) 'waiting)
      (let ([owner (task-owner t)])
        (cond
          [(and (owner-rank owner) (= (owner-instance owner) (task-instance t)))
           (task-state-set! t 'running)
           (run-task-body t)]
          [else (finish! t 'failed (make-quit-condition))]))))

  ;; A task whose resume is dropped can never continue, so it is held
  ;; weakly.
  (define paused-tasks (make-weak-eq-hashtable))

  (define (continue! t state k thunk)
    (when (and (eq? (task-state t) state) (eq? (task-continuation t) k))
      (hashtable-delete! paused-tasks t)
      (task-state-set! t 'running)
      (enter-task! (this-thread-state) t)
      (k thunk)))

  (define (post-task! thunk owner finished)
    (enqueue! (make-task thunk owner (if finished (list finished) '()))))

  (define (post! thunk)
    (unless (procedure? thunk)
      (assertion-violation 'post! "not a procedure" thunk))
    (post-task! thunk (current-owner) #f))

  (define (spawn-task thunk)
    (unless (procedure? thunk)
      (assertion-violation 'spawn-task "not a procedure" thunk))
    (let ([t (make-task thunk (current-owner) '())])
      (task-change-set! t (record-change! 'spawn-task 'task t #f (lambda () (stop-task! t)) void))
      (enqueue! t)
      t))

  (define (stop-task! t)
    (case (task-state t)
      [(waiting) (finish! t 'failed (make-quit-condition))]
      [(paused) (raise-in-paused! t (lambda () (raise (make-quit-condition))))]
      [else (void)]))

  (define (raise-in-paused! t thunk)
    (let ([k (task-continuation t)])
      (task-state-set! t 'signalled)
      (enqueue! (lambda () (continue! t 'signalled k thunk)))))

  (define (make-resume t k)
    (let ([resumed? #f])
      (lambda (thunk)
        (unless (procedure? thunk)
          (assertion-violation 'resume "not a procedure" thunk))
        (with-quit-safe-mutex queue-mutex
          (when resumed?
            (assertion-violation 'resume "the task was resumed already"))
          (set! resumed? #t))
        (enqueue! (lambda () (continue! t 'paused k thunk))))))

  ;; The receiver runs in the task, before it pauses, so a resume it calls
  ;; at once is queued and taken once the task has paused.
  (define (suspend receiver)
    (unless (procedure? receiver)
      (assertion-violation 'suspend "not a procedure" receiver))
    (let ([t (current-task)])
      (unless t
        (assertion-violation 'suspend "not in a task"))
      (let ([body (running-module-body)])
        (when body
          (assertion-violationf 'suspend "the body of module ~s is running" body)))
      (let ([signal (task-signal t)])
        (when signal
          (task-signal-set! t #f)
          (raise (car signal))))
      ((call/cc
         (lambda (k)
           (receiver (make-resume t k))
           (task-continuation-set! t k)
           (task-state-set! t 'paused)
           (hashtable-set! paused-tasks t #t)
           (return-to-loop void))))))

  (define (check-task who v)
    (unless (task? v)
      (assertion-violation who "not a task" v)))

  (define (task-done? t)
    (check-task 'task-done? t)
    (and (memq (task-state t) '(done failed)) #t))

  (define (join-task t)
    (check-task 'join-task t)
    (when (eq? t (current-task))
      (assertion-violation 'join-task "a task cannot wait for itself" t))
    (unless (task-done? t)
      (suspend
        (lambda (resume)
          (task-finishers-set! t (cons (lambda () (resume void)) (task-finishers t))))))
    (if (eq? (task-state t) 'failed)
        (raise (task-result t))
        (apply values (task-result t))))

  ;; Task states change only on the main thread.
  (define (signal-task t v)
    (check-task 'signal-task t)
    (if (on-main-thread?)
        (signal! t v)
        (enqueue! (lambda () (signal! t v)))))

  (define (signal! t v)
    (case (task-state t)
      [(paused) (raise-in-paused! t (lambda () (raise v)))]
      [(waiting running) (task-signal-set! t (list v))]
      [else (void)]))

  (define quit-requests 0)
  (define quit-mutex (make-mutex))

  ;; A second request made before the first quit is handled cannot be
  ;; continued.
  (define quitting? #f)

  (define (request-quit!)
    (with-quit-safe-mutex quit-mutex
      (set! quit-requests (+ quit-requests 1))))

  (define (take-quit-requests!)
    (with-quit-safe-mutex quit-mutex
      (let ([n quit-requests])
        (set! quit-requests 0)
        n)))

  ;; A request made while no task's code runs has nothing to quit, so the
  ;; loop clears requests before and after each item.
  (define (clear-quit-requests!)
    (unless (eqv? quit-requests 0)
      (take-quit-requests!)))

  (define (quit-if-requested!)
    (unless (eqv? quit-requests 0)
      (let ([n (take-quit-requests!)])
        (if (or quitting? (> n 1))
            (raise (make-quit-condition))
            (fluid-let ([quitting? #t])
              (raise-continuable (make-quit-condition)))))))

  (define timer-ticks 1000)
  (define ticking? #f)

  ;; Advice on tick runs inside the handler, so it is not ticked again, and
  ;; a quit waits until it returns rather than landing in it.
  (define (main-timer-interrupt)
    (set-timer timer-ticks)
    (when (and (on-main-thread?) (not ticking?))
      (when (tick-changed?)
        (fluid-let ([ticking? #t])
          (guard (c [#t (report-safely c)])
            (tick))))
      (when (quits-allowed)
        (quit-if-requested!))))

  (define (report-on-main-thread c)
    (if (on-main-thread?)
        (report-safely c)
        (enqueue! (lambda () (report-safely c)))))

  ;; Every thread forked after the loop starts inherits this handler. On
  ;; another thread, reset ends the thread, as fork-thread arranges.
  (define (unhandled-raise c)
    (cond
      [(not (on-main-thread?))
       (report-on-main-thread c)
       (unless (warning-only? c) (reset))]
      [running-task => (lambda (t) (task-raised t c))]
      [else
       (report-safely c)
       (unless (warning-only? c) (reset))]))

  ;; fork-thread makes exit end only its own thread, so on another thread
  ;; the exit is posted to the main thread first, on behalf of (tuna), so
  ;; that it runs even after the thread's module is unloaded.
  (define (exit . arguments)
    (unless (on-main-thread?)
      (post-task! (lambda () (apply chez:exit arguments)) (find-owner '(tuna)) #f))
    (apply chez:exit arguments))

  (define (run-main-loop)
    (timer-interrupt-handler main-timer-interrupt)
    (base-exception-handler unhandled-raise)
    (reset-handler
      (lambda ()
        (let ([t running-task])
          (return-to-loop (if t (lambda () (finish! t 'done '())) void)))))
    (set-timer timer-ticks)
    (run-items! #t))

  (define (run-queued!)
    (run-items! #f))

  ;; Only a spawned task is a change, but every paused task of a module
  ;; would otherwise run its code after the module is gone.
  (add-module-unloaded-handler!
    (lambda (name)
      (vector-for-each
        (lambda (t)
          (when (and (eq? (task-state t) 'paused) (equal? (owner-name (task-owner t)) name))
            (stop-task! t)))
        (hashtable-keys paused-tasks))))

  (record-writer (record-type-descriptor task)
    (lambda (t p wr) (display "#<task>" p))))
