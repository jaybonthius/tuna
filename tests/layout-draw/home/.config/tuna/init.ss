(import (timers))
(import (tuna))
(use-plugin layout)
(import (haml) (console))

;; A short screen keeps the transcripts readable; the layout's own
;; screen is the layout tests' subject.
(define (hello screen client) (haml (:p "Hello from Tuna")))
(advice-add! layout:screen hello)

(define (last-shown client)
  (let ([g (web:given! client)])
    (if (null? g) 'nothing (car (last-pair g)))))

(define (sent screens)
  (let loop ([screens screens] [last #f])
    (cond
      [(null? screens) '()]
      [(equal? (car screens) last) (loop (cdr screens) last)]
      [else (cons (car screens) (loop (cdr screens) (car screens)))])))
