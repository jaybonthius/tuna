(import (tuna) (exit log) (exit keeper) (exit user))

(on-unload (lambda () (exit/log:note! "configuration unloading")))

;; The thread's task is in its body before exit begins, so the unload's
;; stop lands there and its after-thunk runs.
(suspend
  (lambda (resume)
    (fork-task
      (lambda (restore)
        (dynamic-wind
          void
          (lambda () (resume void) (suspend (lambda (resume) (void))))
          (lambda ()
            (exit/log:note! "thread's after-thunk waits")
            (suspend (lambda (resume) (void)))))))))
(exit)
