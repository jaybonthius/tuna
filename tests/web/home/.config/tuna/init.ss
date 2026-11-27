(import (hooks) (options) (tables) (timers) (plugins))
(import (tuna) (testing) (haml) (http))

;; Loaded, not imported, so its unload in a test stays an unload.
(load-module! '(web))
(options:set! web:port (http:free-port))

(http:use-port! (lambda () (web:port)))

(define log (if (top-level-bound? 'log) log '()))
(define (note! x) (set! log (cons x log)))
(define (taken!)
  (let ([l (reverse log)])
    (set! log '())
    l))


(import (console))
