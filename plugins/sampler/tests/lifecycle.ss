(import (tuna) (test) (test-runner) (jobs) (timers) (sampler))

(jobs:define-worker (scripted input emit receive)
  (import (timeseries))
  (let loop ([n 0])
    (receive)
    (case (cadr input)
      [(error) (error 'scripted "the reading failed")]
      [(raise) (raise 'broken)]
      [(slow) (sleep (make-time 'time-duration 0 1))])
    (emit (cons (timeseries-now) (list (car input) n)))
    (loop (+ n 1))))

(define starts 0)
(define behaviour 'ok)
(define readings '())

(define (next-input)
  (set! starts (+ starts 1))
  (list starts behaviour))

(define (note-reading time data) (set! readings (cons data readings)))

(sampler:define-source script scripted next-input note-reading)

;; The configuration's want, as init.ss would make it.
(sampler:want script 0.5)

(test "a want made at the top level, as the configuration makes one, reads with no view open"
  (test-runner:wait-until (lambda () (sampler:last-time script)))
  (let ([first (sampler:last-time script)])
    (test-runner:wait-until (lambda () (> (sampler:last-time script) first)))))

(test "restart! stops the job and starts another with a fresh input"
  (let ([before starts])
    (sampler:restart! script)
    (check-equal? (+ before 1) starts)
    (test-runner:wait-until (lambda () (= (car (car readings)) starts)))))

(test "a reload of the definition keeps the wants and restarts the job"
  (let ([before starts] [wants (sampler:wants script)])
    (sampler:define-source script scripted next-input note-reading)
    (check-equal? wants (sampler:wants script))
    (check-equal? (+ before 1) starts)
    (test-runner:wait-until (lambda () (= (car (car readings)) starts)))))

(sampler:unwant script)

(test "a worker that raises is reported once, stalls the source until its wants change, and is kept as the failure"
  (set! behaviour 'error)
  (let* ([o (make-owner '(viewer failing))]
         [reports (test-runner:reports-during (lambda () (call-as-owner o (lambda () (sampler:want script 0.2)))) 1)]
         [starts-then starts])
    (check-equal? '("the reading failed") (map condition-message reports))
    (test-runner:wait-until (lambda () (sampler:failure script)))
    (check-equal? "the reading failed" (condition-message (sampler:failure script)))
    (timers:sleep 1)
    (check-equal? starts-then starts)
    (set! behaviour 'ok)
    (call-as-owner o (lambda () (sampler:want script 0.3)))
    (check-equal? #f (sampler:failure script))
    (check-equal? (+ starts-then 1) starts)
    (test-runner:wait-until (lambda () (= (car (car readings)) starts)))
    (unload-owner! o)))

(test "taking back a want clears a failure and starts a job"
  (set! behaviour 'error)
  (let ([o (make-owner '(viewer staying))] [p (make-owner '(viewer leaving))])
    (call-as-owner o (lambda () (sampler:want script 0.5)))
    (test-runner:reports-during (lambda () (call-as-owner p (lambda () (sampler:want script 0.2)))) 1)
    (test-runner:wait-until (lambda () (sampler:failure script)))
    (set! behaviour 'ok)
    (let ([starts-then starts])
      (call-as-owner p (lambda () (sampler:unwant script)))
      (check-equal? #f (sampler:failure script))
      (check-equal? (+ starts-then 1) starts)
      (test-runner:wait-until (lambda () (= (car (car readings)) starts))))
    (unload-owner! p)
    (unload-owner! o)))

(test "a worker that raises something other than a condition keeps that value as the failure"
  (set! behaviour 'raise)
  (let ([o (make-owner '(viewer raising))])
    (test-runner:reports-during (lambda () (call-as-owner o (lambda () (sampler:want script 1)))) 1)
    (test-runner:wait-until (lambda () (sampler:failure script)))
    (check-equal? 'broken (sampler:failure script))
    (set! behaviour 'ok)
    (call-as-owner o (lambda () (sampler:restart! script)))
    (check-equal? #f (sampler:failure script))
    (unload-owner! o)))

(test "restart! of a source nobody wants does nothing"
  (let ([before starts])
    (sampler:restart! script)
    (check-equal? before starts)))

(test "a stopped job's last value, arriving after a restart, reaches no on-sample"
  (set! behaviour 'slow)
  (set! readings '())
  (let ([o (make-owner '(viewer restarting))])
    (call-as-owner o (lambda () (sampler:want script 3600)))
    (let ([slow-job starts])
      (set! behaviour 'ok)
      (sampler:restart! script)
      (test-runner:wait-until (lambda () (pair? readings)))
      (timers:sleep 1.5)
      (check-equal? #f (exists (lambda (r) (= (car r) slow-job)) readings))
      (check (for-all (lambda (r) (= (car r) starts)) readings)))
    (unload-owner! o)))
