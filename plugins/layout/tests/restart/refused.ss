(import (tuna) (test) (buffers))

(define notes (buffers:make "notes" "one\n"))

(define reported '())

(define (keep next c) (set! reported (cons c reported)))

(advice-add! report keep)

(import (layout) (views) (document))

(advice-remove! report keep)

(define (contains? s part)
  (let ([n (string-length part)])
    (let loop ([i 0])
      (and (<= (+ i n) (string-length s))
           (or (string=? part (substring s i (+ i n))) (loop (+ i 1)))))))

(test "a saved layout its check refuses is set aside with a warning naming its file, and one view of the first buffer is shown"
  (check-equal? 1 (length reported))
  (check (warning? (car reported)))
  (check (contains? (condition-message (car reported)) "layout/saved-layout.ss"))
  (let ([tree (car (document:datums (buffers:document layout:buffer)))] [v (layout:selected-view)])
    (check-equal? (list 'layout:level '() (vector 'views:view (list (cons 'view (views:id v)) (cons 'buffer "notes")))) tree)))
