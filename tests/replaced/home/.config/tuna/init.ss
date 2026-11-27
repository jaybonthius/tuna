(import (tuna) (testing))
(import (rnrs))
(import (rename (only (chezscheme) sleep fork-thread) (sleep chez:sleep) (fork-thread chez:fork-thread)))

(define (quit-soon)
  (fork-task (lambda (restore) (chez:sleep (make-time 'time-duration 100000000 0))
      (testing:request-quit!))))
(import (console))
