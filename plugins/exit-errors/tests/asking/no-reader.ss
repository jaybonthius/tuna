(import (tuna) (options) (ask) (exit-errors) (exit-errors-test log))

(on-unload (lambda () (exit-errors-test/log:note! "configuration unloading")))

(options:set! ask:y-or-n-reader (lambda (question) (error 'reader "cannot ask")))
(dynamic-wind void (lambda () (exit)) (lambda () (car '())))
(exit-errors-test/log:note! "never")
