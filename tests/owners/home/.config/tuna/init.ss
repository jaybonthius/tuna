(import (tuna))
(import (greet) (spell) (display) (theme))
(import (rename (only (chezscheme) fork-thread) (fork-thread chez:fork-thread)))

(define (on-chez-thread thunk)
  (let ([result #f])
    (thread-join
      (chez:fork-thread
        (lambda ()
          (set! result (guard (c [(message-condition? c) (condition-message c)]) (thunk))))))
    result))
