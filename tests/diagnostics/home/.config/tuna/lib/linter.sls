#!tuna
;; Its own module, so unloading it can be tested.
(import (buffers) (document) (diagnostics))

(define (check b)
  (let ([t (document:text (buffers:document b))])
    (let loop ([i 0] [found '()])
      (cond
        [(> (+ i 3) (string-length t)) (reverse found)]
        [(string=? (substring t i (+ i 3)) "bad")
         (loop (+ i 3) (cons (diagnostics:make-diagnostic (+ i 1) (+ i 4) (diagnostics:severity error) "bad word") found))]
        [else (loop (+ i 1) found)]))))

(add-hook! diagnostics:checkers check)
