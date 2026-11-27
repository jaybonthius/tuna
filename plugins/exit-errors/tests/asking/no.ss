(import (tuna) (test-user) (minibuffer) (exit-errors) (exit-errors-test log) (exit-errors-test user))

(on-unload (lambda () (exit-errors-test/log:note! "configuration unloading")))

(define (exit-with-raise status)
  (spawn-task (lambda (restore) (dynamic-wind void (lambda () (exit status)) (lambda () (car '()))))))

(exit-with-raise 3)
(exit-errors-test/user:answer! "n")
(exit-with-raise 4)
(exit-errors-test/user:answer! "C-g")
(exit-errors-test/log:note! "still running")
(exit)
