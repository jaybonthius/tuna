(import (plugins) (testing))
(import (tuna) (prompts))

(define configuration-task (current-task))

;; The configuration loads as a task, so it can pause; the REPL reads its
;; first form after the configuration has finished.
(define answer
  (suspend (lambda (resume) (spawn-task (lambda (restore) (resume (lambda () 42)))))))
(import (console))
