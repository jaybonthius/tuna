(import (tuna) (test) (test-runner) (plugins)
        (rename (only (chezscheme) sleep) (sleep chez:sleep)))

(define (in-thread thunk)
  (let ([result #f])
    (join-task (fork-task (lambda (restore) (set! result (guard (c [#t (if (message-condition? c) (condition-message c) c)]) (thunk))))))
    result))

(define (spin) (let loop () (loop)))

(define (log) (reverse (getprop 'main-thread 'log '())))
(define (clear-log!) (putprop 'main-thread 'log '()))

;; A user's quit cancels the main thread's running task from another
;; thread.
(define (quit! task) (fork-task (lambda (restore) (cancel-task task))))

;; The main thread is busy on purpose while a thread waits for it, so the
;; thread keeps the deadline: on a miss it cancels the busy task with the
;; reason missed, which its test then sees instead of hanging.
(define (quit-when! started? task)
  (fork-task
    (lambda (restore)
      (let ([deadline (add-duration (current-time 'time-monotonic) (make-time 'time-duration 0 30))])
        (let loop ()
          (cond
            [(started?) (cancel-task task)]
            [(time>? (current-time 'time-monotonic) deadline) (cancel-task task 'missed)]
            [else (chez:sleep (make-time 'time-duration 1000000 0)) (loop)]))))))

;; While the main thread itself waits busily, it keeps its own deadline.
(define (spin-until done?)
  (let ([deadline (add-duration (current-time 'time-monotonic) (make-time 'time-duration 0 30))])
    (let loop ()
      (unless (done?)
        (when (time>? (current-time 'time-monotonic) deadline)
          (errorf 'spin-until "~s did not hold within 30 s" done?))
        (loop)))))

(test "a thread a module forks acts for the module, even when it first calls Tuna while the main thread runs"
  (load-module! '(main-thread forker))
  (let ([env (environment '(main-thread forker))])
    (set-box! (eval 'main-thread/forker:go env) #t)
    (let ([posted (eval 'main-thread/forker:posted env)])
      (spin-until (lambda () (unbox posted)))))
  (test-runner:wait-until (lambda () (pair? (owner-changes (module-owner '(main-thread forker))))))
  (check-equal? '(unload-action) (map car (owner-changes (module-owner '(main-thread forker)))))
  (unload-owner! (module-owner '(main-thread forker))))

(test "a thread forked as an owner acts for that owner"
  (let* ([o (make-owner '(main-thread forking))] [seen #f])
    (join-task (call-as-owner o (lambda () (fork-task (lambda (restore) (set! seen (current-owner)))))))
    (check-equal? o seen)
    (unload-owner! o)))

(test "a thread a module forked is its instance's, so the instance's unload stops it"
  (load-module! '(main-thread poster))
  (let ([env (environment '(main-thread poster))])
    (let ([go (eval 'main-thread/poster:go env)] [ran (eval 'main-thread/poster:ran env)])
      (unload-owner! (module-owner '(main-thread poster)))
      (set-box! go #t)
      (load-module! '(main-thread poster))
      (let ([env (environment '(main-thread poster))])
        (set-box! (eval 'main-thread/poster:go env) #t)
        (test-runner:wait-until (lambda () (unbox (eval 'main-thread/poster:ran env)))))
      (check-equal? #f (unbox ran))))
  (unload-owner! (module-owner '(main-thread poster))))

(test "a quit ends runaway code, and the code after it goes on"
  (let* ([started (box #f)] [t (spawn-task (lambda (restore) (set-box! started #t) (spin)))])
    (let ([reported (test-runner:reports-during
                      (lambda ()
                        (quit-when! (lambda () (unbox started)) t)
                        (check-equal? '(cancelled #f) (call-with-values (lambda () (join-task t)) list)))
                      1)])
      (check-equal? 1 (length reported))
      (check (cancelled? (car reported))))
    (check-equal? 3 (+ 1 2))))

(test "&cancelled is serious and not an error, and a guard that catches every condition catches it"
  (let ([t (spawn-task
             (lambda (restore)
               (list (guard (c [(cancelled? c) (list (serious-condition? c) (error? c))])
                       (quit! (current-task)) (spin))
                     (guard (c [#t 'caught]) (quit! (current-task)) (spin)))))])
    (check-equal? '((#t #f) caught) (test-runner:join t)))
  (check (not (cancelled? (make-error)))))

(test "a first cancel can be handled and continued; a second before the first is handled cannot"
  (let ([quits 0])
    (check-equal? 'continued
      (test-runner:join
        (spawn-task
          (lambda (restore)
            (with-exception-handler
              (lambda (c) (if (cancelled? c) (set! quits (+ quits 1)) (raise c)))
              (lambda () (quit! (current-task)) (let loop () (if (= quits 0) (loop) 'continued)))))))))
  (let ([t (spawn-task
             (lambda (restore)
               (with-exception-handler
                 (lambda (c) (if (cancelled? c) (begin (quit! (current-task)) (spin)) (raise c)))
                 (lambda () (quit! (current-task)) (spin)))))])
    (let ([reported (test-runner:reports-during (lambda () (join-task t)) 1)])
      (check-equal? 1 (length reported))
      (check (cancelled? (car reported))))
    (check-equal? 'done (task-state t))))

(test "a cancel ends a module's body, and the module is unloaded"
  (check-raises cancelled? (load-module! '(main-thread runaway)))
  (test-runner:wait-until (lambda () (not (module-owner '(main-thread runaway))))))

(test "after a warning, the code that raised it goes on"
  (let ([reported (test-runner:reports-during (lambda () (check-equal? 'went-on (begin (warning 'careful "watch out") 'went-on))) 1)])
    (check-equal? 1 (length reported))
    (check (warning? (car reported)))))

(test "report gets a condition no handler takes before the stack unwinds"
  (let ([where (make-thread-parameter 'outside)] [seen #f])
    (define (show-where next c) (set! seen (where)) (next c))
    (let ([reported (test-runner:reports-during
                      (lambda ()
                        (advice-add! report show-where)
                        (join-task (spawn-task (lambda (restore) (parameterize ([where 'inside]) (car 1)))))
                        (advice-remove! report show-where))
                      1)])
      (check-equal? 1 (length reported)))
    (check-equal? 'inside seen)))

(test "a raise on another thread is reported and ends that thread; after a warning the thread goes on"
  (let ([finished? #f])
    (let ([reported (test-runner:reports-during (lambda () (join-task (fork-task (lambda (restore) (car 5) (set! finished? #t))))) 1)])
      (check-equal? 1 (length reported))
      (check (assertion-violation? (car reported))))
    (check-equal? #f finished?)
    (let ([reported (test-runner:reports-during (lambda () (join-task (fork-task (lambda (restore) (warning 'thread "careful") (set! finished? #t))))) 1)])
      (check-equal? 1 (length reported))
      (check (warning? (car reported))))
    (check-equal? #t finished?)))

(test "reset ends the task that calls it"
  (let* ([after #f] [t (spawn-task (lambda (restore) (reset) (set! after #t)))])
    (join-task t)
    (check-equal? #f after)))

(test "the configuration loads as a task, which may pause"
  (let ([home (string-append (getenv "HOME") "/configured")])
    (test-runner:make-home! home)
    (call-with-output-file (string-append home "/.config/tuna/init.ss")
      (lambda (p)
        (put-string p "(import (tuna))\n(define configuration-task (current-task))\n")
        (put-string p "(define answer (suspend (lambda (resume) (spawn-task (lambda (restore) (resume (lambda () 42)))))))\n")))
    (let-values ([(status errors) (test-runner:run-file "main-thread-files/paused-configuration.ss" home)])
      (check-equal? 0 status)
      (check-equal? "" errors))))

(test "a test file runs in a task, and a paused task lets others go on until any thread resumes it"
  (check (task? (current-task)))
  (let* ([saved #f]
         [asking (spawn-task (lambda (restore) (suspend (lambda (resume) (set! saved resume)))))])
    (test-runner:wait-until (lambda () saved))
    (check-equal? 'paused (task-state asking))
    (join-task (fork-task (lambda (restore) (saved (lambda () 'yes)))))
    (check-equal? 'yes (test-runner:join asking))))

(test "a task that raises is reported, join-task gives the same condition, and a task cannot join itself"
  (let ([failing #f])
    (let ([reported (test-runner:reports-during (lambda () (set! failing (spawn-task (lambda (restore) (error 'nap "woke badly")))) (join-task failing)) 1)])
      (check-equal? 1 (length reported))
      (check-equal? (car reported) (guard (c [#t c]) (test-runner:join failing)))))
  (check-raises assertion-violation? (join-task (current-task))))

(test "a task starts after the tasks already waiting on the main thread"
  (let ([order '()])
    (spawn-task (lambda (restore) (set! order (cons 'first order))))
    (let ([second (spawn-task (lambda (restore) (set! order (cons 'second order))))])
      (join-task second)
      (check-equal? '(first second) (reverse order)))))

(test "a task is resumed once, from any thread, and suspend returns the thunk's value computed in the task"
  (let* ([p (make-thread-parameter 'outside)] [winds '()] [saved #f]
         [kept (spawn-task
                 (lambda (restore)
                   (parameterize ([p 'inside])
                     (dynamic-wind
                       (lambda () (set! winds (cons 'in winds)))
                       (lambda () (suspend (lambda (resume) (set! saved resume))))
                       (lambda () (set! winds (cons 'out winds)))))))])
    (test-runner:wait-until (lambda () saved))
    (check-equal? '(in out) (reverse winds))
    (join-task (fork-task (lambda (restore) (saved p))))
    (check-equal? 'inside (test-runner:join kept))
    (check-equal? '(in out in out) (reverse winds))
    (check-raises assertion-violation? (saved (lambda () 2)))))

(test "a thread's task pauses, and may spawn a task that runs on the main thread; a module's body cannot pause"
  (check-equal? 'resumed (in-thread (lambda () (suspend (lambda (resume) (resume (lambda () 'resumed)))))))
  (let ([main (get-thread-id)])
    (check-equal? main (test-runner:join (in-thread (lambda () (spawn-task (lambda (restore) (get-thread-id)))))))
    (check-raises assertion-violation? (load-module! '(main-thread pauser)))))

(test "another thread's cancel is delivered"
  (let ([signalled (spawn-task (lambda (restore) (suspend (lambda (resume) (void)))))])
    (test-runner:wait-until (lambda () (eq? (task-state signalled) 'paused)))
    (let ([reported (test-runner:reports-during (lambda () (join-task (fork-task (lambda (restore) (cancel-task signalled 'from-thread)))) (join-task signalled)) 1)])
      (check-equal? 1 (length reported))
      (check (cancelled? (car reported))))
    (check-equal? 'from-thread (guard (c [(cancelled? c) (cancelled-reason c)]) (test-runner:join signalled)))))

(test "unloading a module stops its paused tasks past their handlers, after running what it spawned before"
  (clear-log!)
  (load-module! '(main-thread waiter))
  (let ([waiter (module-owner '(main-thread waiter))])
    (call-as-owner waiter (lambda () ((eval 'main-thread/waiter:wait-forever (environment '(main-thread waiter))))))
    (call-as-owner waiter (lambda () ((eval 'main-thread/waiter:later (environment '(main-thread waiter))) 'spawned-before)))
    (unload-owner! waiter)
    (check-equal? '(spawned-before) (log))
    (check-equal? '() (filter (lambda (t) (eq? (task-owner t) waiter)) (live-tasks)))))

(test "work an instance spawned before a reload was asked for runs before the reload begins"
  (clear-log!)
  (load-module! '(main-thread waiter))
  (call-as-owner (module-owner '(main-thread waiter))
    (lambda () ((eval 'main-thread/waiter:later (environment '(main-thread waiter))) 'reloaded-instance)))
  (reload-modules! '((main-thread waiter)))
  (check-equal? '(reloaded-instance) (log))
  (unload-owner! (module-owner '(main-thread waiter))))

(test "tick runs on the main thread about every thousand procedure calls, while advised"
  (let ([samples 0] [threads '()])
    (define (sample tick)
      (set! samples (+ samples 1))
      (unless (memv (get-thread-id) threads) (set! threads (cons (get-thread-id) threads)))
      (tick))
    (define (busy n) (if (= n 0) 0 (+ 1 (busy (- n 1)))))
    (advice-add! tick sample)
    (let loop ([i 0]) (when (< i 200) (busy 10000) (loop (+ i 1))))
    (advice-remove! tick sample)
    (check (> samples 100))
    (check-equal? (list (get-thread-id)) threads)
    (let ([before samples])
      (busy 100000)
      (check-equal? before samples))))

