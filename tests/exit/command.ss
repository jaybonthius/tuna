(import (tuna) (timers) (exit log) (exit keeper) (exit user))

(on-unload (lambda () (exit/log:note! "configuration unloading")))

(import (commands))
(commands:define-command (leave) "Exits." (dynamic-wind void (lambda () (exit)) (lambda () (car '()))))
(commands:run leave)
(exit/log:note! "never")
