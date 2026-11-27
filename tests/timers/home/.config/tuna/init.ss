(import (timers) (plugins) (testing))
(import (tuna))

(define log '())
(define (note! x) (set! log (cons x log)))

(define (on-thread thunk)
  (let ([result #f])
    (join-task (fork-task (lambda (restore) (set! result (guard (c [#t (condition-message c)]) (thunk))))))
    result))
(import (console))
