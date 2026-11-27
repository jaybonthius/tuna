#!tuna
;; As a user's interrupt would, a request from any thread cancels the main
;; thread's task that is running, if one is: tick runs in it. A task
;; paused there runs no code to interrupt.
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
