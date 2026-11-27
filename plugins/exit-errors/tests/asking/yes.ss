(import (tuna) (test-user) (minibuffer) (exit-errors) (exit-errors-test log) (exit-errors-test user))

(on-unload (lambda () (exit-errors-test/log:note! "configuration unloading")))

(spawn-task (lambda (restore) (exit-errors-test/user:answer! "y")))
(dynamic-wind void (lambda () (exit)) (lambda () (car '())))
(exit-errors-test/log:note! "never")
