#!tuna
(import (files) (hooks))
(define (mode) 'text)
(define (handler path)
  (let ([n (string-length path)])
    (and (> n 4) (string=? (substring path (- n 4) n) ".txt") mode)))
(hooks:add! files:find-handlers handler)
