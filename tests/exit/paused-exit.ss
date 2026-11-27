(import (tuna) (test-runner) (exit log) (exit keeper) (exit user))

(on-unload (lambda () (exit/log:note! "configuration unloading")))

(define exiting? #f)
(define paused
  (spawn-task
    (lambda (restore)
      (dynamic-wind
        void
        (lambda () (suspend (lambda (resume) (void))))
        (lambda () (when exiting? (exit/user:say-leaving) (exit 9)))))))
(test-runner:wait-until (lambda () (eq? (task-state paused) 'paused)))
(set! exiting? #t)
(exit)
