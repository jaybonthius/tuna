(library (tuna core main-thread)
  (export
    post!
    post-task!
    request-quit!
    report-on-main-thread
    &quit
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
          (only (tuna core modules) running-module-body))

  (define-condition-type &quit &serious make-quit-condition quit-condition?)

  (define-record-type task
    (nongenerative)
    (sealed #t)
    (fields thunk owner
            (mutable state)
            (mutable continuation)
            (mutable result)
            (mutable finishers)
            (mutable signal)
            (mutable change))
    (protocol
      (lambda (new)
        (lambda (thunk owner finishers)
          (new thunk owner 'waiting #f #f finishers #f #f)))))

  (define queue-mutex (make-mutex))
  (define queue-ready (make-condition))
  (define queue-head '())
  (define queue-tail '())
  (define queue-closed? #f)

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
      (set! queue-head '())))

  (define (dequeue! wait?)
    (with-quit-safe-mutex queue-mutex
      (let loop ()
        (cond
          [(pair? queue-head)
           (let ([item (car queue-head)])
             (set! queue-head (cdr queue-head))
             item)]
          [wait? (condition-wait queue-ready queue-mutex) (loop)]
          [else #f]))))

  (define running-task #f)
  (define return-to-loop #f)

  (define (current-task)
    (and (on-main-thread?) running-task))

  (define (run-item! item)
    (let ([outer-return return-to-loop] [outer-task running-task])
      (clear-quit-requests!)
      (call/cc
        (lambda (k)
          (set! return-to-loop k)
          (set! running-task #f)
          (item)))
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

  ;; A raise no handler takes is reported before the stack unwinds, so
  ;; advice on report and Chez's debugger see where it was raised.
  (define (run-task-body t)
    (let ([outcome
           (call/cc
             (lambda (end)
               (parameterize ([current-owner (task-owner t)]
                              [reset-handler (lambda () (end '(done)))]
                              [quits-allowed #t])
                 (call-reporting-raises
                   (lambda ()
                     (call-with-values (task-thunk t) (lambda results (cons 'done results))))
                   (lambda (c)
                     (when (debug-on-exception)
                       (debug-condition c)
                       (debug))
                     (end (cons 'failed c)))))))])
      (finish! t (car outcome) (cdr outcome))
      (return-to-loop (void))))

  (define (start! t)
    (when (eq? (task-state t) 'waiting)
      (cond
        [(owner-rank (task-owner t))
         (task-state-set! t 'running)
         (set! running-task t)
         (run-task-body t)]
        [else (finish! t 'failed (make-quit-condition))])))

  (define (continue! t state k thunk)
    (when (and (eq? (task-state t) state) (eq? (task-continuation t) k))
      (task-state-set! t 'running)
      (set! running-task t)
      (k thunk)))

  (define (post-task! thunk owner finished)
    (let ([t (make-task thunk owner (if finished (list finished) '()))])
      (enqueue! (lambda () (start! t)))))

  (define (post! thunk)
    (unless (procedure? thunk)
      (assertion-violation 'post! "not a procedure" thunk))
    (post-task! thunk (current-owner) #f))

  (define (spawn-task thunk)
    (unless (procedure? thunk)
      (assertion-violation 'spawn-task "not a procedure" thunk))
    (let ([t (make-task thunk (current-owner) '())])
      (task-change-set! t (record-change! 'spawn-task 'task t #f (lambda () (stop-task! t)) void))
      (enqueue! (lambda () (start! t)))
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
           (return-to-loop (void)))))))

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

  ;; Every thread forked after the loop starts inherits this handler. Each
  ;; task handles its own raises, so on the main thread only the loop's
  ;; code gets here; on another thread, reset ends the thread, as
  ;; fork-thread arranges.
  (define (unhandled-raise c)
    (report-on-main-thread c)
    (unless (warning-only? c)
      (reset)))

  ;; fork-thread makes exit end only its own thread, so on another thread
  ;; the exit is posted to the main thread first, on behalf of (tuna), so
  ;; that it runs even after the thread's module is unloaded.
  (define (exit . arguments)
    (unless (on-main-thread?)
      (post-task! (lambda () (apply chez:exit arguments)) '(tuna) #f))
    (apply chez:exit arguments))

  (define (run-main-loop)
    (check-main-thread 'run-main-loop)
    (timer-interrupt-handler main-timer-interrupt)
    (base-exception-handler unhandled-raise)
    (reset-handler (lambda () (return-to-loop (void))))
    (set-timer timer-ticks)
    (let loop ()
      (run-item! (dequeue! #t))
      (loop)))

  (define (run-queued!)
    (let ([item (dequeue! #f)])
      (when item
        (run-item! item)
        (run-queued!))))

  (record-writer (record-type-descriptor task)
    (lambda (t p wr) (display "#<task>" p))))
