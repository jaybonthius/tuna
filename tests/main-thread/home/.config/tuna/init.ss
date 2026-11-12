(import (tuna) (prompts))

(define configuration-task (current-task))

;; The configuration loads as a task, so it can pause; the REPL reads its
;; first form after the configuration has finished.
(define answer
  (suspend (lambda (resume) (post! (lambda () (resume (lambda () 42)))))))
(import (console))
