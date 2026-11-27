(import (tuna) (timers) (exit log) (exit keeper) (exit user))

(on-unload (lambda () (exit/log:note! "configuration unloading")))

(import (rename (only (chezscheme) fork-thread) (fork-thread chez:fork-thread)))
(define returned? #f)
(on-unload (lambda () (exit/log:note! (if returned? "exit returned" "exit did not return"))))
(chez:fork-thread (lambda () (exit) (set! returned? #t)))
(timers:sleep 5)
(exit/log:note! "never")
