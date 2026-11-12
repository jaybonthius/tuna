(import (tuna) (tuna eval))

(define log '())
(define (note! x) (set! log (cons x log)))

(define (on-thread thunk)
  (let ([result #f])
    (thread-join (fork-thread (lambda () (set! result (guard (c [#t (condition-message c)]) (thunk))))))
    result))
(import (console))
