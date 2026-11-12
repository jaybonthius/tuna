(import (tuna) (tuna plugins))
(use-plugin web)
(use-plugin display)
(import (haml) (console))

(define (last-shown client)
  (let ([g (web:given! client)])
    (if (null? g) 'nothing (car (last-pair g)))))

(define (sent screens)
  (let loop ([screens screens] [last #f])
    (cond
      [(null? screens) '()]
      [(equal? (car screens) last) (loop (cdr screens) last)]
      [else (cons (car screens) (loop (cdr screens) (car screens)))])))
