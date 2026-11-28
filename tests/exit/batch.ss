(import (tuna) (exit log) (exit keeper) (exit user))

(on-unload (lambda () (exit/log:note! "configuration unloading")))

(define changed (box "before"))

(advice-add! batch-ended (lambda (next) (exit/log:note! (format "batch ended: ~a" (unbox changed))) (next)))

(set-box! changed "changed in the exiting batch")
(exit)
