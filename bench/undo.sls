#!tuna
(import (undo) (buffers) (document))

;; The main thread's own processor time, so the writer's work on its
;; thread, which shares the one CPU, is left out.
(define thread-cpu-ns
  (let ([clock-gettime (begin (load-shared-object #f) (foreign-procedure "clock_gettime" (int uptr) int))])
    (lambda ()
      (let ([ts (foreign-alloc 16)])
        (clock-gettime 3 ts)
        (let ([ns (+ (* (foreign-ref 'long ts 0) 1000000000) (foreign-ref 'long ts 8))])
          (foreign-free ts)
          ns)))))

(define (now-ns)
  (let ([t (current-time 'time-monotonic)])
    (+ (* (time-second t) 1000000000) (time-nanosecond t))))

(define (median xs)
  (list-ref (list-sort < xs) (quotient (length xs) 2)))

(define (show name value)
  (printf "~a ~,2f\n" name value))

(define (cpu-ns-per-op n thunk)
  (median
    (map (lambda (k)
           (collect-rendezvous)
           (let ([start (thread-cpu-ns)])
             (do ([i 0 (fx+ i 1)]) ((fx= i n)) (thunk))
             (/ (- (thread-cpu-ns) start) (exact->inexact n))))
         (iota 9))))

(define (cpu-ns-difference n with without)
  (define (sample thunk)
    (collect-rendezvous)
    (let ([start (thread-cpu-ns)])
      (do ([i 0 (fx+ i 1)]) ((fx= i n)) (thunk))
      (/ (- (thread-cpu-ns) start) (exact->inexact n))))
  (median
    (map (lambda (k)
           (if (even? k)
               (let* ([a (sample with)] [b (sample without)]) (- a b))
               (let* ([b (sample without)] [a (sample with)]) (- a b))))
         (iota 15))))

(define (record-cost)
  (let ([kept (buffers:make "kept" "\n")] [plain (buffers:make "plain" "\n")])
    (buffers:with-buffer plain (set-option-local! undo:limit 0))
    (cpu-ns-difference 2000
      (lambda () (buffers:replace! kept 1 1 "x"))
      (lambda () (buffers:replace! plain 1 1 "x")))))

(define (batch-end-cost record)
  (let ([kept (buffers:make "batch" "\n")] [plain (buffers:make "plain-batch" "\n")])
    (buffers:with-buffer plain (set-option-local! undo:limit 0))
    (- (cpu-ns-difference 300
         (lambda () (buffers:replace! kept 1 1 "x") (batch-ended))
         (lambda () (buffers:replace! plain 1 1 "x") (batch-ended)))
       record)))

(define (move-cost)
  (let ([b (buffers:make "moves" (make-string 100000 #\m))])
    (buffers:replace! b 50000 50000 "word ")
    (batch-ended)
    (let ([id (car (undo:history b))])
      (/ (cpu-ns-per-op 1000 (lambda () (undo:go-to! b 0) (undo:go-to! b id))) 2.0))))

(define (run)
  (let ([record (record-cost)])
    (show "record-ns" record)
    (show "batch-end-ns" (batch-end-cost record)))
  (show "undo-step-us" (/ (move-cost) 1000.0)))
