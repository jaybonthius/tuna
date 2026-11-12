(import (tuna) (tuna plugins) (tuna eval) (jobs))
(use-plugin fuzzy (local "~/src/fuzzy"))

(define log '())
(define (note! x) (set! log (cons x log)))
(define (taken!)
  (let ([l (reverse log)])
    (set! log '())
    l))

;; Waits until the job has ended and its on-end has run, so a transcript
;; shows what reached on-result and on-end.
(define (finished worker input)
  (suspend
    (lambda (resume)
      (let ([values '()])
        (jobs:start worker input
          (lambda (v) (set! values (cons v values)))
          (lambda (ended) (resume (lambda () (list (reverse values) ended)))))))))

(define (wait-until done?)
  (let loop ([n 0])
    (unless (or (done?) (= n 1000))
      (sleep-for 0.01)
      (loop (+ n 1)))))
(import (console))
