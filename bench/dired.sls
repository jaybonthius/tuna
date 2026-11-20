#!tuna
(import (document) (buffers) (views) (layout) (undo) (dired) (web) (haml))

(define (now-ns)
  (let ([t (current-time 'time-monotonic)])
    (+ (* (time-second t) 1000000000) (time-nanosecond t))))

(define (median xs)
  (list-ref (list-sort < xs) (quotient (length xs) 2)))

(define batch 200)

(define (ns-per-op thunk)
  (median
    (map (lambda (k)
           (collect-rendezvous)
           (let ([start (now-ns)])
             (do ([i 0 (fx+ i 1)]) ((fx= i batch)) (thunk))
             (/ (- (now-ns) start) (exact->inexact batch))))
         (iota 9))))

(define (show name value)
  (printf "~a ~,2f\n" name value))

(define client (web:add-client! 1))

(define (entries b)
  (let ([doc (buffers:document b)])
    (let loop ([p 0] [n 0])
      (if (fx>= p (document:length doc))
          n
          (let ([t (document:token doc p)])
            (loop (fx+ p 1) (if (and (document:node? t) (eq? (document:node-kind t) 'dired:%entry)) (fx+ n 1) n)))))))

(define (run folder)
  (let ([b (dired:visit folder)] [v (layout:selected-view)])
    (let wait ([n 0])
      (unless (or (fx>= (entries b) 62) (fx= n 1000))
        (sleep-for 0.01)
        (wait (fx+ n 1))))
    (unless (fx>= (entries b) 62) (printf "the folder was not read\n"))
    (views:set-buffer! v b)
    (show "dired-draw-60" (ns-per-op (lambda () (html->bytevector (views:draw v client)))))))
