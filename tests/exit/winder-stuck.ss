(import (tuna) (exit log) (exit keeper) (exit user))

(on-unload (lambda () (exit/log:note! "configuration unloading")))

(spawn-task
  (lambda (restore)
    (dynamic-wind
      void
      (lambda () (suspend (lambda (resume) (void))))
      (lambda ()
        (exit/log:note! "after-thunk waits")
        (suspend (lambda (resume) (void)))))))

;; The task above runs to its pause before exit stops it.
(suspend (lambda (resume) (spawn-task (lambda (restore) (resume void)))))
(exit)
