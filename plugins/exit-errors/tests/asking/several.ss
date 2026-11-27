(import (tuna) (test-user) (minibuffer) (exit-errors) (exit-errors-test log) (exit-errors-test user))

(on-unload (lambda () (exit-errors-test/log:note! "configuration unloading")))

(spawn-task
  (lambda (restore)
    (dynamic-wind void
      (lambda () (dynamic-wind void (lambda () (exit 5)) (lambda () (vector-ref (vector) 0))))
      (lambda () (car '())))))
(exit-errors-test/user:answer! "y")
(exit-errors-test/user:answer! "n")
(exit-errors-test/log:note! "still running")
(exit)
