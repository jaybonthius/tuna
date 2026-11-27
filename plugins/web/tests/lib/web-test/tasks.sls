#!tuna
(import (test-runner))

;; A task spawned now runs after the tasks queued before it, and the
;; resume it queues while the caller is paused runs only once their batch
;; has ended.
(define (settle)
  (suspend (lambda (resume) (spawn-task (lambda (restore) (resume void))))))

;; A report that comes from the server's threads arrives later, in a task
;; of its own, so the caller says how many to wait for.
(define reports-during
  (case-lambda
    [(thunk) (reports-during thunk 0)]
    [(thunk count)
     (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
       (advice-add! report keep)
       (thunk)
       (settle)
       (test-runner:wait-until (lambda () (>= (length reported) count)))
       (advice-remove! report keep)
       (reverse reported))]))
