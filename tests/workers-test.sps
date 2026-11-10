(import (chezscheme) (tuna test) (chez-lang loader)
        (tuna core changes) (tuna core definitions) (tuna core modules)
        (except (tuna core main-thread) exit) (tuna timers) (tuna workers))

(define root
  (let ([dir (format "/tmp/tuna-workers-test-~a" (get-process-id))])
    (mkdir dir)
    dir))

(define (write-library! name text)
  (call-with-output-file (string-append root "/lib/" name ".sls")
    (lambda (p) (put-string p text))))

(mkdir (string-append root "/lib"))
(for-each
  (lambda (name)
    (write-library! name
      (format "(library (~a) (export answer) (import (chezscheme)) (define (answer) '~a))\n" name name)))
  '("plain-a" "plain-b" "plain-c" "plain-d"))

(compile-file-message #f)
(install-module-lookup! (library-directories) (string-append root "/lib") (string-append root "/library")
  (string-append root "/cache") (lambda (name) #f) (lambda (name) #f) (lambda (name) #f) (lambda () '()))
(install-loader!)

(define main-thread-id (get-thread-id))

(define (job-changes)
  (filter (lambda (change) (eq? (car change) 'job)) (module-changes '(repl))))

(define (wait-for-jobs running)
  (let loop ([n 0])
    (when (and (> (length (job-changes)) running) (< n 1000))
      (sleep-for 0.01)
      (loop (+ n 1)))))

(define (wait-for-jobs-to-end) (wait-for-jobs 0))

(define (wait-until-called receive-done)
  (suspend (lambda (resume) (receive-done (lambda () (resume void))))))

(define-worker (count-up input)
  (let ([id (car input)] [n (cdr input)])
    (do ([i 0 (+ i 1)]) ((= i n)) (emit (list id i)))))

(define-worker (spin x) (let loop () (loop)))

(define-worker (nothing x) (void))

(define-worker (fails x) (car x))

(define-worker (warns x) (warning 'warns "careful") (emit 'went-on))

(define-worker (answer-a x) (import (plain-a)) (emit (answer)))
(define-worker (answer-b x) (import (plain-b)) (emit (answer)))
(define-worker (answer-c x) (import (plain-c)) (emit (answer)))
(define-worker (answer-d x) (import (plain-d)) (emit (answer)))

(define (tests)
  (test "results from many jobs at once each arrive on the main thread, in order"
    (let ([results (make-vector 8 '())] [threads '()] [received 0] [jobs 8] [n 2000])
      (wait-until-called
        (lambda (done)
          (do ([id 0 (+ id 1)]) ((= id jobs))
            (start-job count-up (cons id n)
              (lambda (v)
                (set! threads (cons (get-thread-id) threads))
                (vector-set! results (car v) (cons (cadr v) (vector-ref results (car v))))
                (set! received (+ received 1))
                (when (= received (* jobs n)) (done)))))))
      (check (for-all (lambda (id) (= id main-thread-id)) threads))
      (check (for-all (lambda (rs) (equal? (reverse rs) (iota n))) (vector->list results)))
      (wait-for-jobs-to-end)
      (check-equal? '() (job-changes))))

  ;; Chez's library manager allows one thread at a time to load libraries.
  (test "first jobs compile and import while the main thread loads modules"
    (do ([i 0 (+ i 1)]) ((= i 30))
      (write-library! (format "loaded~a" i) (format "#!tuna\n(define (f) ~a)\n" i)))
    (let ([answers '()] [workers (list answer-a answer-b answer-c answer-d)])
      (wait-until-called
        (lambda (done)
          (for-each
            (lambda (w)
              (do ([i 0 (+ i 1)]) ((= i 4))
                (start-job w 0
                  (lambda (v)
                    (set! answers (cons v answers))
                    (when (= (length answers) 16) (done))))))
            workers)
          (do ([i 0 (+ i 1)]) ((= i 30))
            (load-module! (list (string->symbol (format "loaded~a" i)))))))
      (check-equal? '(plain-a plain-a plain-a plain-a plain-b plain-b plain-b plain-b
                      plain-c plain-c plain-c plain-c plain-d plain-d plain-d plain-d)
                    (list-sort (lambda (a b) (string<? (symbol->string a) (symbol->string b))) answers))
      (check (module-loaded? '(loaded29)))
      (wait-for-jobs-to-end)))

  (test "stop-job! ends runaway jobs, whether or not their bodies have started"
    (let ([early (map (lambda (i) (start-job spin i void)) (iota 10))]
          [late (map (lambda (i) (start-job spin i void)) (iota 10))])
      (for-each stop-job! early)
      (wait-for-jobs 10)
      (sleep-for 0.05)
      (let ([running (map cadr (job-changes))])
        (check-equal? 10 (length running))
        (check (for-all (lambda (j) (memq j running)) late)))
      (for-each stop-job! late)
      (wait-for-jobs-to-end)
      (check-equal? '() (job-changes))))

  (test "a worker's raise reaches report on the main thread; after a warning it goes on"
    (let ([reported '()] [results '()])
      (define (note report c)
        (set! reported (cons (list (= (get-thread-id) main-thread-id) (condition-who c)) reported)))
      (advice-add! report note)
      (start-job fails 1 void)
      (start-job warns 1 (lambda (v) (set! results (cons v results))))
      (wait-for-jobs-to-end)
      (advice-remove! report note)
      (check-equal? '((#t car) (#t warns))
                    (list-sort (lambda (a b) (string<? (symbol->string (cadr a)) (symbol->string (cadr b))))
                               reported))
      (check-equal? '(went-on) results)))

  (test "only the main thread starts a job, and only a worker emits"
    (let ([messages '()])
      (thread-join
        (fork-thread
          (lambda ()
            (set! messages
              (map (lambda (thunk) (guard (c [#t (condition-message c)]) (thunk) #f))
                   (list (lambda () (start-job nothing 0 void))
                         (lambda () (emit 1))))))))
      (check-equal? '("only the main thread makes changes" "not in a worker") messages)))

  (test "a quit never leaves a job half started"
    (let ([quits 0])
      (do ([i 0 (+ i 1)]) ((= i 100))
        (guard (c [(quit-condition? c) (set! quits (+ quits 1))])
          (request-quit!)
          (let loop ()
            (stop-job! (start-job nothing 0 void))
            (loop))))
      (check-equal? 100 quits)
      (wait-for-jobs-to-end)
      (check-equal? '() (job-changes)))))

(post! (lambda ()
         (tests)
         (system (format "rm -rf '~a'" root))
         (test-exit)))
(run-main-loop)
