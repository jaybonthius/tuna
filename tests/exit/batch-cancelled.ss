(import (tuna) (exit log) (exit keeper) (exit user))

(on-unload (lambda () (exit/log:note! "configuration unloading")))

;; As a watchdog would cancel a batch-ended that runs too long.
(advice-add! batch-ended
  (lambda (next)
    (exit/log:note! "batch-ended cancels itself")
    (cancel-task (current-task) 'watchdog)
    (suspend (lambda (resume) (void)))))

(exit)
