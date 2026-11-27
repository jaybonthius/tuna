#!tuna
(import (hot-paths))

(define (winds)
  (let ([m (make-mutex)])
    (hot-paths:measure "dynamic-wind" 5000000 1
      (lambda (n)
        (let loop ([i 0] [acc 0])
          (if (fx= i n) acc (loop (fx+ i 1) (dynamic-wind void (lambda () (fx+ acc 1)) void))))))
    (hot-paths:measure "with-mutex" 5000000 1
      (lambda (n)
        (let loop ([i 0] [acc 0])
          (if (fx= i n) acc (loop (fx+ i 1) (with-mutex m (fx+ acc 1)))))))))

;; Each item posts the next, so each is a batch of its own.
(define (post-chain n)
  (collect-rendezvous)
  (let ([start (hot-paths:now-ns)])
    (suspend
      (lambda (resume)
        (let next ([left n])
          (spawn-task (lambda (restore) (if (fx= left 0) (resume void) (next (fx- left 1))))))))
    (/ (- (hot-paths:now-ns) start) (exact->inexact n))))

(define (pass-on ended) (ended))

;; Unadvised, batch-ended is not called at all, so its cost is the
;; difference that advice makes.
(define (batches)
  (let loop ([k 0] [plain '()] [advised '()])
    (if (= k 9)
        (printf "batch-ended ~,2f\n" (- (hot-paths:median advised) (hot-paths:median plain)))
        (let ([p (post-chain 20000)])
          (advice-add! batch-ended pass-on)
          (let ([a (post-chain 20000)])
            (advice-remove! batch-ended pass-on)
            (loop (+ k 1) (cons p plain) (cons a advised)))))))

(define (run)
  (winds)
  (batches))
