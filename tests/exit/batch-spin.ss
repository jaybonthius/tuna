(import (tuna) (exit log) (exit keeper) (exit user))

(on-unload (lambda () (exit/log:note! "configuration unloading")))

(advice-add! batch-ended
  (lambda (next)
    (exit/log:note! "batch-ended spins")
    (let spin () (spin))))

(exit)
