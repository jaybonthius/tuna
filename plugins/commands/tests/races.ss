(import (tuna) (test) (test-runner) (hooks) (commands)
        (rename (only (chezscheme) sleep) (sleep chez:sleep)))

(define events '())

(define (event! . e) (set! events (cons e events)))

(define (take-events!) (let ([e (reverse events)]) (set! events '()) e))

(define (on-thread thunk)
  (let ([result #f])
    (join-task (fork-task (lambda (restore) (set! result (guard (c [(assertion-violation? c) (list 'raised (condition-message c))]) (thunk))))))
    result))

(define ended '())

(define (note-end c) (set! ended (cons c ended)))

(hooks:add! commands:after-command note-end)

(commands:define-command (plain) "Does nothing." 'plain)

(commands:define-command (forking) "Asks a thread for the running command."
  (list (commands:this-command) (on-thread (lambda () (list 'running (commands:this-command))))))

(define resume-waiting #f)

(commands:define-command (waiting [x (suspend (lambda (resume) (set! resume-waiting resume)))])
  "Pauses for its argument, then notes what it sees."
  (event! 'waiting x (commands:this-command) (commands:last-command))
  x)

(commands:define-command (broken) "Raises." (car '()))

(define (start-waiting)
  (set! resume-waiting #f)
  (let ([paused (spawn-task (lambda (restore) (commands:run waiting)))])
    (test-runner:wait-until (lambda () resume-waiting))
    paused))

(test "another thread reads the registry and the last command, sees no running command, and cannot run one"
  (check-equal? 'plain (commands:run plain))
  (check-equal? '(raised "not on the main thread") (on-thread (lambda () (commands:run plain))))
  (check-equal? #t (on-thread (lambda () (commands:command? plain))))
  (check-equal? (commands:command-name plain) (on-thread (lambda () (commands:command-name plain))))
  (check-equal? #t (on-thread (lambda () (eq? (commands:command-named (commands:command-name plain)) plain))))
  (check-equal? (commands:command-names) (on-thread commands:command-names))
  (check-equal? #t (on-thread (lambda () (eq? (commands:last-command) plain)))))

(test "a thread a command forks sees no running command"
  (check-equal? (list forking '(running #f)) (commands:run forking)))

(test "a command paused in one task keeps its own running command and last command while commands run and end in another"
  (let ([paused (start-waiting)])
    (check-equal? #f (commands:this-command))
    (check (eq? forking (commands:last-command)))
    (check-equal? 'plain (commands:run plain))
    (resume-waiting (lambda () 'resumed))
    (check-equal? 'resumed (test-runner:join paused)))
  (check-equal? (list (list 'waiting 'resumed waiting forking)) (take-events!))
  (check (eq? waiting (commands:last-command))))

(test "a raise or a cancel reaching a paused command is reported when it resumes, and its run ends"
  (set! ended '())
  (let* ([paused (start-waiting)]
         [reported (test-runner:reports-during
                     (lambda ()
                       (resume-waiting (lambda () (raise 'cancelled)))
                       (check-equal? '() (call-with-values (lambda () (test-runner:join paused)) list))))])
    (check-equal? '(cancelled) reported))
  (let* ([paused (start-waiting)]
         [reported (test-runner:reports-during
                     (lambda ()
                       (cancel-task paused 'stop)
                       (check-equal? '() (call-with-values (lambda () (test-runner:join paused)) list))))])
    (check-equal? 1 (length reported))
    (check (cancelled? (car reported))))
  (check-equal? '() (take-events!))
  (check-equal? (list waiting waiting) ended))

(test "a report that pauses ends the run once it returns, so after-command runs once"
  (set! ended '())
  (let* ([reported '()]
         [pausing (lambda (next c)
                    (suspend (lambda (resume) (fork-task (lambda (restore) (chez:sleep (make-time 'time-duration 10000000 0)) (resume void)))))
                    (set! reported (cons c reported)))])
    (advice-add! report pausing)
    (check-equal? '() (call-with-values (lambda () (test-runner:join (spawn-task (lambda (restore) (commands:run broken))))) list))
    (advice-remove! report pausing)
    (check-equal? 1 (length reported)))
  (check-equal? (list broken) ended))

;; While the main thread itself waits busily, it keeps its own deadline.
(define (spin-until done?)
  (let ([deadline (add-duration (current-time 'time-monotonic) (make-time 'time-duration 0 30))])
    (let loop ()
      (unless (done?)
        (when (time>? (current-time 'time-monotonic) deadline)
          (errorf 'spin-until "~s did not hold within 30 s" done?))
        (loop)))))

(define runs 0)

(commands:define-command (busy [n 200])
  "Counts to N."
  (let loop ([i 0]) (if (< i n) (loop (+ i 1)) (set! runs (+ runs 1)))))

(test "quits landing in runs, hooks and bookkeeping leave nothing running, and a run then calls each hook once"
  (let* ([quitting #t] [stopped #f] [quits-reported 0] [quits-caught 0] [stressed (current-task)] [until (+ (real-time) 1500)]
         [count-quits (lambda (next c) (if (cancelled? c) (set! quits-reported (+ quits-reported 1)) (next c)))])
    (advice-add! report count-quits)
    ;; A user's quit cancels the main thread's running task from another
    ;; thread, landing up to a thousand calls after it is asked for, so the
    ;; one guard holds from before the first until after the last has
    ;; landed: a quit between two guards would end the test.
    (let again ()
      (guard (c [(cancelled? c) (set! quits-caught (+ quits-caught 1)) (again)])
        (when (= quits-caught quits-reported 0)
          (fork-task
            (lambda (restore)
              (let loop ()
                (if quitting
                    (begin
                      (cancel-task stressed)
                      (chez:sleep (make-time 'time-duration 1000000 0))
                      (loop))
                    (set! stopped #t))))))
        (let loop ()
          (when (< (real-time) until)
            (commands:run busy)
            (loop)))
        (set! quitting #f)
        (spin-until (lambda () stopped))
        (let settle ([n 0]) (when (< n 100000) (settle (+ n 1))))))
    (advice-remove! report count-quits)
    (check (> quits-reported 100))
    (check (> runs 1000)))
  (let ([before (lambda (c) (event! 'before c))] [after (lambda (c) (event! 'after c))])
    (hooks:add! commands:before-command before)
    (hooks:add! commands:after-command after)
    (take-events!)
    (check-equal? #f (commands:this-command))
    (check-equal? 'plain (commands:run plain))
    (check-equal? (list (list 'before plain) (list 'after plain)) (take-events!))
    (check (eq? plain (commands:last-command)))
    (hooks:remove! commands:before-command before)
    (hooks:remove! commands:after-command after)))
