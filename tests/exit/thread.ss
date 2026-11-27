(import (tuna) (timers) (exit log) (exit keeper) (exit user))

(on-unload (lambda () (exit/log:note! "configuration unloading")))

(import (exit place))
(join-task (fork-task (lambda (restore) (exit) (exit/log:note! "never"))))
(exit/log:note! "never")
