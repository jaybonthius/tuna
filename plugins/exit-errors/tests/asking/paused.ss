(import (tuna) (options) (ask) (test-user) (commands) (keys) (exit-errors) (exit-errors-test log))

(on-unload (lambda () (exit-errors-test/log:note! "configuration unloading")))

(options:set! ask:y-or-n-reader (lambda (question) (exit-errors-test/log:note! "asked") #f))

(commands:define-command (leave) "Exits." (exit))
(keys:bind! keys:global "C-x C-c" leave)

(define exiting? #f)

(spawn-task
  (lambda (restore)
    (guard (c [#t (exit-errors-test/log:note! "handler ran")
                  (spawn-task (lambda (restore) (exit-errors-test/log:note! "new work")))])
      (dynamic-wind
        void
        (lambda () (suspend (lambda (resume) (void))))
        (lambda () (when exiting? (car '())))))))
(test-user:settle)
(set! exiting? #t)
(test-user:press! "C-x C-c")
(exit-errors-test/log:note! "never")
