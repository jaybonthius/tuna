(import (tuna) (options) (ask) (test-runner) (exit-errors) (exit-errors-test log))

(on-unload (lambda () (exit-errors-test/log:note! "configuration unloading")))

(options:set! ask:y-or-n-reader (lambda (question) (exit-errors-test/log:note! "asked") #f))

(define exiting? #f)

(define raised? #f)

(spawn-task
  (lambda (restore)
    (test-runner:wait-until (lambda () exiting?))
    (set! raised? #t)
    (vector-ref (vector) 0)))
(dynamic-wind void
  (lambda () (set! exiting? #t) (exit))
  (lambda () (test-runner:wait-until (lambda () raised?))))
(exit-errors-test/log:note! "never")
