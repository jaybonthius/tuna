#!tuna
(import (test-runner) (test-user) (exit-errors-test log))

(define (%questions)
  (test-user:elements (test-user:screen) "minibuffer-question"))

(define (answer! keys)
  (test-user:settle)
  (test-runner:wait-until (lambda () (pair? (%questions))))
  (exit-errors-test/log:note! (string-append "asked: " (test-user:element-text (car (%questions)))))
  (test-user:press! keys))
