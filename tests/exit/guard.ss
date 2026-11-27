(import (tuna) (timers) (exit log) (exit keeper) (exit user))

(on-unload (lambda () (exit/log:note! "configuration unloading")))

(guard (c [#t (exit/log:note! "handler ran")])
  (dynamic-wind
    void
    (lambda () (dynamic-wind void (lambda () (exit)) (lambda () (car '()))))
    (lambda () (exit/user:say-leaving))))
(exit/log:note! "never")
