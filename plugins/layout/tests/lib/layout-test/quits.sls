#!tuna
;; A user's quit cancels whichever task the main thread is running, and
;; tick runs in that task. A paused task runs no code to interrupt, so a
;; quit asked for while the main thread's task pauses lands nowhere.
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
