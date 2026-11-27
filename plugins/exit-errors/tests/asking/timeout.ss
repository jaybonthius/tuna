(import (tuna) (minibuffer) (exit-errors) (exit-errors-test log))

(on-unload (lambda () (exit-errors-test/log:note! "configuration unloading")))

(dynamic-wind void (lambda () (exit)) (lambda () (car '())))
(exit-errors-test/log:note! "never")
