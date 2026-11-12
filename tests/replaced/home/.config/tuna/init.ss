(import (tuna))
(import (rnrs))
(import (rename (only (chezscheme) sleep fork-thread) (sleep chez:sleep) (fork-thread chez:fork-thread)))

(define (quit-soon)
  (fork-thread
    (lambda ()
      (chez:sleep (make-time 'time-duration 100000000 0))
      (request-quit!))))
(import (console))
