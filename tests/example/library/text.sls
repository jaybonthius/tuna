#!tuna
(import (files))
(define (mode) 'text)
(define (handler path)
  (let ([n (string-length path)])
    (and (> n 4) (string=? (substring path (- n 4) n) ".txt") mode)))
(add-hook! files:find-handlers handler)
