(import (tuna) (timers) (exit log) (exit keeper) (exit user))

(on-unload (lambda () (exit/log:note! "configuration unloading")))

(dynamic-wind void (lambda () (exit)) (lambda () (exit 2)))
