(import (tuna) (testing) (tuna plugins) (haml) (http))

(use-plugin web
  (config
    (set-option! web:port (http:free-port))))

(http:use-port! (lambda () (web:port)))

(define log '())
(define (note! x) (set! log (cons x log)))
(define (taken!)
  (let ([l (reverse log)])
    (set! log '())
    l))


(import (console))
