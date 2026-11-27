#!tuna
(import (timers))

;; A limit long enough for a loaded machine costs a passing test nothing;
;; at the limit the wait raises, so a condition that never holds fails its
;; test instead of letting it go on without what it waited for.
(define (wait-until done?)
  (let loop ([n 0])
    (cond
      [(done?) (void)]
      [(= n 3000) (error 'testing:wait-until "timed out")]
      [else (timers:sleep 0.01) (loop (+ n 1))])))

(define (done? task) (eq? (task-state task) 'done))

;; A test reads a task's end as its values, or as its raise raised again.
(define (join task)
  (let-values ([(how detail) (join-task task)])
    (case how
      [(returned) (apply values detail)]
      [(raised) (raise detail)]
      [(cancelled) (raise (make-cancelled detail))]
      [else (raise (make-cancelled how))])))

;; As a user's interrupt would, a request from any thread cancels the
;; main thread's task that is running, if one is: tick runs in it. A task
;; paused there runs no code to interrupt, and the tests that wait in a
;; pause while another thread asks rely on it.
(define %running (box #f))
(define %main-thread (get-thread-id))

(define (request-quit!)
  (let ([t (if (eqv? (get-thread-id) %main-thread) (current-task) (unbox %running))])
    (when (and t (eq? (task-state t) 'running))
      (cancel-task t))))

(advice-add! tick
  (lambda (next)
    (set-box! %running (current-task))
    (next)))
