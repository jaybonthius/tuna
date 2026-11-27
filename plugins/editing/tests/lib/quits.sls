#!tuna
;; A quit key the page posts lands only while the key's task still runs,
;; which a mouse command, done in microseconds, has mostly ended by the
;; time the cancel arrives. Cancelling the task the main thread runs,
;; found through tick, which runs in it, reaches such a command as a
;; user's interrupt would.
(define %running (box #f))

(define %requests 0)

(define (requests) %requests)

(define (request-quit! spared)
  (let ([t (unbox %running)])
    (when (and t (not (eq? t spared)) (eq? (task-state t) 'running))
      (set! %requests (+ %requests 1))
      (cancel-task t))))

(advice-add! tick
  (lambda (next)
    (set-box! %running (current-task))
    (next)))
