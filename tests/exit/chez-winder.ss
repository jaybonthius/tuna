(import (tuna) (timers) (exit log) (exit keeper) (exit user))

(on-unload (lambda () (exit/log:note! "configuration unloading")))

(import (prefix (only (chezscheme) dynamic-wind) chez:))
(guard (c [#t (exit/log:note! "handler ran")])
  (chez:dynamic-wind void (lambda () (exit)) (lambda () (car '()))))
(exit/log:note! "the task goes on")
(timers:sleep 0.05)
(exit/log:note! "after a pause")
