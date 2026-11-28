(import (tuna) (exit log) (exit keeper) (exit user))

(on-unload (lambda () (exit/log:note! "configuration unloading")))

(advice-add! batch-ended
  (lambda (next)
    (exit/log:note! "batch-ended waits")
    (suspend (lambda (resume) (void)))))

(exit)
