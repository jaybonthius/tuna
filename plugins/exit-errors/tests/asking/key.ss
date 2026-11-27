(import (tuna) (test-user) (commands) (keys) (minibuffer) (exit-errors) (exit-errors-test log) (exit-errors-test user))

(on-unload (lambda () (exit-errors-test/log:note! "configuration unloading")))

(commands:define-command (leave) "Exits." (dynamic-wind void (lambda () (exit)) (lambda () (car '()))))
(keys:bind! keys:global "C-x C-c" leave)
(spawn-task (lambda (restore) (exit-errors-test/user:answer! "y")))
(test-user:press! "C-x C-c")
