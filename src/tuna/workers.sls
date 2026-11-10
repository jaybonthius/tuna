(library (tuna workers)
  (export
    define-worker
    start-job
    stop-job!
    emit
    worker?
    job?)
  (import (chezscheme) (tuna core changes) (tuna plain-data)
          (only (tuna core conditions) warning-only?)
          (only (tuna core definitions) define-exported)
          (only (tuna core modules) call-with-quit-safe-library-lock import-spec-library)
          (only (tuna core main-thread) post-task! report-on-main-thread make-quit-condition
                quit-condition?))

  ;; The body is kept as a datum and compiled on the first job, on the
  ;; job's thread, so defining a worker costs nothing.
  (define-record-type worker
    (nongenerative)
    (sealed #t)
    (fields name imports source (mutable procedure))
    (protocol
      (lambda (new)
        (lambda (name imports source)
          (new name imports source #f)))))

  (define-record-type job
    (nongenerative)
    (sealed #t)
    (fields worker owner on-result (mutable stop?) (mutable taken-back?) (mutable change))
    (protocol
      (lambda (new)
        (lambda (worker owner on-result)
          (new worker owner on-result #f #f #f)))))

  (define-syntax define-worker
    (lambda (x)
      (syntax-case x (import)
        [(_ (id input) (import spec ...) body1 body2 ...)
         (and (identifier? #'id) (identifier? #'input))
         #'(define-exported id (make-worker 'id '(spec ...) '(lambda (input) body1 body2 ...)))]
        [(_ (id input) body1 body2 ...)
         (and (identifier? #'id) (identifier? #'input))
         #'(define-exported id (make-worker 'id '() '(lambda (input) body1 body2 ...)))])))

  ;; A local import in Chez's own environment, because Chez never frees an
  ;; environment. Loading and invoking libraries is for one thread at a
  ;; time, so both happen under the lock: Chez would otherwise invoke an
  ;; import at the body's first reference to it, outside. The lock also
  ;; makes the first jobs to start compile the body once. A stop waits
  ;; until the body runs, so it never lands inside Chez's compiler.
  (define (worker-procedure! w)
    (or (worker-procedure w)
        (call-with-quit-safe-library-lock
          (lambda ()
            (or (worker-procedure w)
                (let ([p (eval `(let () (import (tuna worker) ,@(worker-imports w)) ,(worker-source w))
                               (scheme-environment))])
                  (for-each (lambda (spec) (invoke-library (import-spec-library spec))) (worker-imports w))
                  (worker-procedure-set! w p)
                  p))))))

  (define current-emit (make-thread-parameter #f))

  (define (emit v)
    (let ([send (current-emit)])
      (unless send
        (assertion-violation 'emit "not in a worker"))
      (unless (plain-data? v)
        (assertion-violation 'emit "not plain data" v))
      (send v)))

  ;; Results still queued when the job's module unloads or reloads would
  ;; reach code of an instance that is gone.
  (define (send-result j v)
    (post-task! (lambda () (unless (job-taken-back? j) ((job-on-result j) v))) (job-owner j) #f))

  (define job-ticks 1000)

  ;; Chez cannot interrupt another thread, so a job polls for its stop on
  ;; its own timer, and only where quits may land.
  (define (job-timer-interrupt j)
    (lambda ()
      (set-timer job-ticks)
      (when (and (job-stop? j) (quits-allowed))
        (job-stop?-set! j #f)
        (raise (make-quit-condition)))))

  ;; A stopped job is what its starter asked for, so its quit is not
  ;; reported. The job's end is posted as the stack unwinds because Chez's
  ;; exit, reset and abort in a worker end its thread by escaping past the
  ;; body. It is posted on behalf of (tuna), so the job's change is
  ;; forgotten even after its module unloads.
  (define (run-job j input)
    (parameterize ([current-emit (lambda (v) (send-result j v))]
                   [timer-interrupt-handler (job-timer-interrupt j)])
      (dynamic-wind
        (lambda () (set-timer job-ticks))
        (lambda ()
          (call/cc
            (lambda (k)
              (with-exception-handler
                (lambda (c)
                  (unless (quit-condition? c)
                    (report-on-main-thread c))
                  (unless (warning-only? c)
                    (k (void))))
                (lambda ()
                  (let ([p (worker-procedure! (job-worker j))])
                    (with-quits-allowed #t (p input))))))))
        (lambda ()
          (set-timer 0)
          (post-task! (lambda () (forget-change! (job-change j))) (find-owner '(tuna)) #f)))))

  (define (start-job w input on-result)
    (unless (worker? w)
      (assertion-violation 'start-job "not a worker" w))
    (unless (plain-data? input)
      (assertion-violation 'start-job "not plain data" input))
    (unless (procedure? on-result)
      (assertion-violation 'start-job "not a procedure" on-result))
    (let ([j (make-job w (current-owner) on-result)])
      (with-quits-allowed #f
        (job-change-set! j
          (record-change! 'start-job 'job j #f
            (lambda () (job-taken-back?-set! j #t) (job-stop?-set! j #t))
            void))
        (fork-thread (lambda () (run-job j input))))
      j))

  (define (stop-job! j)
    (unless (job? j)
      (assertion-violation 'stop-job! "not a job" j))
    (job-stop?-set! j #t))

  (record-writer (record-type-descriptor worker)
    (lambda (w p wr) (fprintf p "#<worker ~a>" (worker-name w))))

  (record-writer (record-type-descriptor job)
    (lambda (j p wr) (display "#<job>" p))))
