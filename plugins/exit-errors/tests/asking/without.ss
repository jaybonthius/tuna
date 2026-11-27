(import (tuna) (test-user) (commands) (keys) (exit-errors-test log))

(on-unload (lambda () (exit-errors-test/log:note! "configuration unloading")))

(commands:define-command (leave) "Exits." (dynamic-wind void (lambda () (exit)) (lambda () (car '()))))
(keys:bind! keys:global "C-x C-c" leave)
(test-user:press! "C-x C-c")
(exit-errors-test/log:note! "never")
