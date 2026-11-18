(import (tuna) (tuna plugins) (haml) (http))

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

(define (wait-until done?)
  (let loop ([n 0])
    (unless (or (done?) (= n 500))
      (sleep-for 0.01)
      (loop (+ n 1)))))

(import (console))
