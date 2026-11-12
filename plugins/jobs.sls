#!tuna
(import (rename (only (chezscheme) set-timer timer-interrupt-handler)
                (set-timer chez:set-timer)
                (timer-interrupt-handler chez:timer-interrupt-handler)))

;; The internals are in a module form, so that they stay private and a
;; job's thread runs no changeable definition: a job keeps running the code
;; it started with when this module reloads.
(module ((define-worker make-worker) start-job send-to-job! stop-job! freeze-vector
         job-record? worker-record?)

  (define main-thread (get-thread-id))

  (define result-limit 64)
  (define job-ticks 1000)

  (define-record-type (worker make-worker worker-record?)
    (sealed #t)
    (fields name imports source (mutable procedure))
    (protocol
      (lambda (new)
        (lambda (name imports source)
          (new name imports source #f)))))

  ;; stoppable? is #f while the job's thread runs this module's code,
  ;; which takes mutexes that a stop must not leave held. A quit can land
  ;; in a delivery before it counts its value, so delivered is the number
  ;; of the newest value delivered, not a count: a later delivery makes up
  ;; for a lost one.
  (define-record-type (job make-job job-record?)
    (sealed #t)
    (fields worker owner on-result on-end mutex wake
            (mutable inputs-front) (mutable inputs-back) (mutable sent) (mutable delivered)
            (mutable stop?) (mutable ended?) (mutable dropped?) (mutable stoppable?))
    (protocol
      (lambda (new)
        (lambda (worker owner on-result on-end)
          (new worker owner on-result on-end (make-mutex) (make-condition)
               '() '() 0 0 #f #f #f #f)))))

  ;; A quit can land anywhere in code on the main thread, and one between a
  ;; change to a job and its condition-signal would lose the wake-up, so the
  ;; main thread holds a job's mutex only with interrupts disabled. A
  ;; blocked acquire with interrupts disabled would keep a collection
  ;; waiting for the main thread, so it only tries the mutex, which a job
  ;; holds for a few instructions at a time.
  (define-syntax with-job-mutex
    (syntax-rules ()
      [(_ j e1 e2 ...)
       (let ([m (job-mutex j)])
         (if (eqv? (get-thread-id) main-thread)
             (let retry ()
               (unless (with-interrupts-disabled
                         (and (mutex-acquire m #f)
                              (begin e1 e2 ... (mutex-release m) #t)))
                 (retry)))
             (with-mutex m e1 e2 ...)))]))

  (define-syntax define-worker
    (lambda (x)
      (define (head? ids)
        (and (for-all identifier? ids) (fx<= (length ids) 4)))
      (syntax-case x (import)
        [(_ (id input emit receive ...) (import spec ...) body1 body2 ...)
         (head? #'(id input emit receive ...))
         #'(define-public id
             (make-worker 'id '(spec ...) '(lambda (input emit receive ...) body1 body2 ...)))]
        [(_ (id input emit receive ...) body1 body2 ...)
         (head? #'(id input emit receive ...))
         #'(define-public id
             (make-worker 'id '() '(lambda (input emit receive ...) body1 body2 ...)))])))

  (define (plain-atom? v)
    (or (number? v) (char? v) (string? v) (symbol? v) (boolean? v) (bytevector? v) (null? v)))

  (define frozen-mutex (make-mutex))
  (define frozen-vectors (make-weak-eq-hashtable))

  (define (registered? v) (eq-hashtable-contains? frozen-vectors v))

  (define (frozen? v) (with-mutex frozen-mutex (registered? v)))

  (define (plain-walk? v skip?)
    (if (or (pair? v) (vector? v))
        (let ([marks (make-eq-hashtable)])
          (define (walk v)
            (cond
              [(pair? v) (walk-list v '())]
              [(vector? v)
               (case (eq-hashtable-ref marks v #f)
                 [(done) #t]
                 [(walking) #f]
                 [else
                  (or (and (immutable-vector? v) (skip? v))
                      (begin
                        (eq-hashtable-set! marks v 'walking)
                        (let ([n (vector-length v)])
                          (let loop ([i 0])
                            (cond
                              [(fx= i n) (eq-hashtable-set! marks v 'done) #t]
                              [(walk (vector-ref v i)) (loop (fx+ i 1))]
                              [else #f])))))])]
              [else (plain-atom? v)]))
          (define (walk-list p spine)
            (cond
              [(pair? p)
               (case (eq-hashtable-ref marks p #f)
                 [(done) (finish spine)]
                 [(walking) #f]
                 [else
                  (eq-hashtable-set! marks p 'walking)
                  (and (walk (car p)) (walk-list (cdr p) (cons p spine)))])]
              [else (and (walk p) (finish spine))]))
          (define (finish spine)
            (for-each (lambda (p) (eq-hashtable-set! marks p 'done)) spine)
            #t)
          (walk v))
        (plain-atom? v)))

  ;; plain-data? would walk a frozen vector every time; here it counts as
  ;; walked. The first walk sets each immutable vector aside and looks
  ;; them all up at once, so a check takes the mutex once rather than once
  ;; per frozen vector, and holds it during no walk. A vector set aside is
  ;; not walked for cycles, so when one is not frozen the check walks
  ;; again and looks each up as it reaches it.
  (define (sendable? v)
    (let ([held '()])
      (and (plain-walk? v (lambda (v) (set! held (cons v held)) #t))
           (or (null? held)
               (with-mutex frozen-mutex (for-all registered? held))
               (plain-walk? v frozen?)))))

  (define (check-sendable who v)
    (unless (sendable? v)
      (assertion-violation who "not plain data" v)))

  (define (freeze-vector v)
    (unless (vector? v)
      (assertion-violation 'jobs:freeze "not a vector" v))
    (check-sendable 'jobs:freeze v)
    (let ([frozen (vector->immutable-vector v)])
      (with-mutex frozen-mutex (eq-hashtable-set! frozen-vectors frozen #t))
      frozen))

  (define (import-spec-library spec)
    (if (and (pair? spec) (memq (car spec) '(only except prefix rename add-prefix drop-prefix alias for library)))
        (import-spec-library (cadr spec))
        spec))

  (define (uses-tuna? name)
    (let ([seen (make-hashtable equal-hash equal?)])
      (let walk ([name name])
        (cond
          [(eq? (car name) 'tuna) #t]
          [(hashtable-contains? seen name) #f]
          [else
           (hashtable-set! seen name #t)
           (exists walk (library-requirements name))]))))

  ;; A local import in Chez's own environment, because Chez never frees an
  ;; environment made by environment. Evaluating the import loads and
  ;; invokes the libraries here, on the main thread, the only thread that
  ;; loads libraries. A body must be stoppable, whatever settings code on
  ;; the main thread has left.
  (define (worker-procedure! w)
    (or (worker-procedure w)
        (let* ([specs (worker-imports w)]
               [p (parameterize ([optimize-level 2]
                                 [generate-interrupt-trap #t]
                                 [enable-unsafe-application #f]
                                 [enable-unsafe-variable-reference #f])
                    (eval (if (null? specs)
                              (worker-source w)
                              `(let () (import ,@specs) ,(worker-source w)))
                          (scheme-environment)))])
          (for-each
            (lambda (spec)
              (let ([name (import-spec-library spec)])
                (when (uses-tuna? name)
                  (assertion-violation (worker-name w) "a worker cannot import a library that uses Tuna" name))))
            specs)
          (let ([p (if (fx= (procedure-arity-mask p) 4)
                       (lambda (input emit receive) (p input emit))
                       p)])
            (worker-procedure-set! w p)
            p))))

  ;; One unload action per owner stops all its jobs, so a thousand jobs
  ;; make one change, not a thousand.
  (define jobs-by-owner (make-hashtable equal-hash equal?))

  (define (remember! j)
    (let ([owner (job-owner j)])
      (unless (hashtable-contains? jobs-by-owner owner)
        (on-unload
          (lambda ()
            (let ([jobs (hashtable-ref jobs-by-owner owner #f)])
              (hashtable-delete! jobs-by-owner owner)
              (when jobs
                (vector-for-each
                  (lambda (j) (job-dropped?-set! j #t) (stop-job! j))
                  (hashtable-keys jobs))))))
        (hashtable-set! jobs-by-owner owner (make-eq-hashtable)))
      (eq-hashtable-set! (hashtable-ref jobs-by-owner owner #f) j #t)))

  (define (forget! j)
    (let ([jobs (hashtable-ref jobs-by-owner (job-owner j) #f)])
      (when jobs (eq-hashtable-delete! jobs j))))

  ;; While a job's thread holds its mutex, the main thread retries for it,
  ;; and a quit landing between tries would lose the count of every
  ;; delivery until the job lets go; if those are the job's last values, it
  ;; waits for room forever. The count runs as the in of Tuna's
  ;; dynamic-wind, which holds quits off.
  (define (deliver! j n v)
    (unless (job-dropped? j)
      (dynamic-wind
        (lambda ()
          (with-job-mutex j
            (let ([half (fxsrl result-limit 1)] [before (fx- (job-sent j) (job-delivered j))])
              (job-delivered-set! j (fxmax n (job-delivered j)))
              (when (and (fx> before half) (fx<= (fx- (job-sent j) (job-delivered j)) half))
                (condition-signal (job-wake j))))))
        (lambda () ((job-on-result j) v))
        void)))

  ;; What the body raised comes tagged, since it may be #f or stopped.
  (define (finish! j ended)
    (unless (job-dropped? j)
      (forget! j)
      ((job-on-end j)
       (if (pair? ended)
           (let ([raised (cdr ended)]) (report raised) raised)
           ended))))

  ;; Runs on the job's thread with stops held off, since it takes the
  ;; job's mutex.
  (define (queue-result! j v)
    (let ([n (with-mutex (job-mutex j)
               (let wait ()
                 (when (and (fx>= (fx- (job-sent j) (job-delivered j)) result-limit) (not (job-stop? j)))
                   (condition-wait (job-wake j) (job-mutex j))
                   (wait)))
               (and (not (job-stop? j))
                    (let ([n (fx+ (job-sent j) 1)])
                      (job-sent-set! j n)
                      n)))])
      (and n (begin (post! (lambda () (deliver! j n v))) #t))))

  (define (seconds->time-utc seconds)
    (let ([ns (exact (round (* seconds 1000000000)))])
      (add-duration (current-time 'time-utc)
        (make-time 'time-duration (remainder ns 1000000000) (quotient ns 1000000000)))))

  (define stop-mark (list 'stopped))

  ;; Runs on the job's thread with stops held off, since it takes the
  ;; job's mutex.
  (define (take-input! j until)
    (with-mutex (job-mutex j)
      (let wait ()
        (cond
          [(job-stop? j) stop-mark]
          [(pair? (job-inputs-front j))
           (let ([v (car (job-inputs-front j))])
             (job-inputs-front-set! j (cdr (job-inputs-front j)))
             v)]
          [(pair? (job-inputs-back j))
           (job-inputs-front-set! j (reverse (job-inputs-back j)))
           (job-inputs-back-set! j '())
           (wait)]
          [(condition-wait (job-wake j) (job-mutex j) until) (wait)]
          [(job-stop? j) stop-mark]
          [else (eof-object)]))))

  ;; Chez cannot interrupt another thread, so the job's own timer ends it.
  ;; Every way out of the body first turns stoppable? off and then escapes
  ;; to end, so no stop lands as the job ends. The body sees Chez's exit,
  ;; reset and abort, which end only the job. An emit or receive after a
  ;; stop escapes from wherever it is, a critical wind included, so the
  ;; job may end with interrupts disabled.
  (define (run-job j p input)
    (let ([ended
           (call/cc
             (lambda (end)
               (define (end-with reason)
                 (job-stoppable?-set! j #f)
                 (end reason))
               (define (end-raised c) (end-with (cons 'raised c)))
               (define (emit v)
                 (job-stoppable?-set! j #f)
                 (cond
                   [(not (sendable? v))
                    (job-stoppable?-set! j #t)
                    (assertion-violation 'emit "not plain data" v)]
                   [(queue-result! j v) (job-stoppable?-set! j #t)]
                   [else (end-with 'stopped)]))
               (define (receive-until until)
                 (job-stoppable?-set! j #f)
                 (let ([v (take-input! j until)])
                   (if (eq? v stop-mark)
                       (end-with 'stopped)
                       (begin (job-stoppable?-set! j #t) v))))
               (define receive
                 (case-lambda
                   [() (receive-until #f)]
                   [(seconds)
                    (unless (and (real? seconds) (>= seconds 0))
                      (assertion-violation 'receive "not a number of seconds" seconds))
                    (receive-until (and (finite? seconds) (seconds->time-utc seconds)))]))
               (chez:timer-interrupt-handler
                 (lambda ()
                   (if (and (job-stop? j) (job-stoppable? j))
                       (end-with 'stopped)
                       (chez:set-timer job-ticks))))
               (parameterize ([exit-handler (lambda arguments (end-with #f))]
                              [reset-handler (lambda () (end-with #f))]
                              [abort-handler (case-lambda [() (end-with #f)] [(x) (end-with #f)])])
                 ;; The outer handler takes the error raised when the inner
                 ;; one returns from a warning raised with raise, which
                 ;; cannot go on.
                 (with-exception-handler end-raised
                   (lambda ()
                     (with-exception-handler
                       (lambda (c)
                         (cond
                           [(and (warning? c) (not (serious-condition? c)))
                            (job-stoppable?-set! j #f)
                            (post! (lambda () (report c)))
                            (job-stoppable?-set! j #t)]
                           [else (end-raised c)]))
                       (lambda ()
                         (job-stoppable?-set! j #t)
                         (chez:set-timer job-ticks)
                         (p input emit receive)
                         (end-with #f))))))))])
      (chez:set-timer 0)
      (let enable () (unless (fx= (enable-interrupts) 0) (enable)))
      (with-mutex (job-mutex j) (job-ended?-set! j #t))
      (post! (lambda () (finish! j ended)))))

  (define (start-job w input on-result on-end)
    (unless (worker-record? w)
      (assertion-violation 'jobs:start "not a worker" w))
    (unless (procedure? on-result)
      (assertion-violation 'jobs:start "not a procedure" on-result))
    (unless (procedure? on-end)
      (assertion-violation 'jobs:start "not a procedure" on-end))
    (unless (eqv? (get-thread-id) main-thread)
      (assertion-violation 'jobs:start "not on the main thread"))
    (check-sendable 'jobs:start input)
    (let ([p (worker-procedure! w)] [j (make-job w (current-owner) on-result on-end)])
      (remember! j)
      (fork-thread (lambda () (run-job j p input)))
      j))

  (define (send-to-job! j v)
    (unless (job-record? j)
      (assertion-violation 'jobs:send! "not a job" j))
    (check-sendable 'jobs:send! v)
    (with-job-mutex j
      (unless (job-ended? j)
        (job-inputs-back-set! j (cons v (job-inputs-back j)))
        (condition-signal (job-wake j)))))

  (define (stop-job! j)
    (unless (job-record? j)
      (assertion-violation 'jobs:stop! "not a job" j))
    (with-job-mutex j
      (job-stop?-set! j #t)
      (condition-signal (job-wake j))))

  (record-writer (record-type-descriptor worker)
    (lambda (w p wr) (fprintf p "#<worker ~a>" (worker-name w))))

  (record-writer (record-type-descriptor job)
    (lambda (j p wr) (fprintf p "#<job ~a>" (worker-name (job-worker j))))))

(define start
  (case-lambda
    [(w input on-result) (start-job w input on-result (lambda (ended) (void)))]
    [(w input on-result on-end) (start-job w input on-result on-end)]))

(define (send! j v) (send-to-job! j v))

(define (stop! j) (stop-job! j))

(define (freeze v) (freeze-vector v))

(define (job? v) (job-record? v))

(define (worker? v) (worker-record? v))
