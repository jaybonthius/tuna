#!tuna
(import (document) (buffers) (kill-ring))

(define (now-ns)
  (let ([t (current-time 'time-monotonic)])
    (+ (* (time-second t) 1000000000) (time-nanosecond t))))

(define (median xs)
  (list-ref (list-sort < xs) (quotient (length xs) 2)))

(define (ns-per-op batch thunk)
  (median (map (lambda (k) (ns-per-op-once batch thunk)) (iota 9))))

;; Samples of the two alternate, each going first in turn, since the
;; second of two runs on one buffer measures about a microsecond slower.
(define (ns-per-op-pair batch a b)
  (let loop ([k 0] [as '()] [bs '()])
    (cond
      [(fx= k 10) (values (median as) (median bs))]
      [(fxeven? k)
       (let* ([x (ns-per-op-once batch a)] [y (ns-per-op-once batch b)])
         (loop (fx+ k 1) (cons x as) (cons y bs)))]
      [else
       (let* ([y (ns-per-op-once batch b)] [x (ns-per-op-once batch a)])
         (loop (fx+ k 1) (cons x as) (cons y bs)))])))

(define (ns-per-op-once batch thunk)
  (collect-rendezvous)
  (let ([start (now-ns)])
    (do ([i 0 (fx+ i 1)]) ((fx= i batch)) (thunk))
    (/ (- (now-ns) start) (exact->inexact batch))))

(define (show name value)
  (printf "~a ~,2f\n" name value))

(define copies 0)

(define line (make-string 80 #\k))

;; A full ring, so each push drops the oldest entry.
(define (fill-ring! size)
  (do ([i 0 (fx+ i 1)]) ((fx= i 120))
    (kill-ring:push! (list (make-string size (integer->char (fx+ 97 (fxmod i 26))))))))

(buffers:define-layer responses (travels) (sticky after))

;; The kill of a line in a chat transcript, which carries travelling spans.
(define (line-buffer)
  (let ([b (buffers:make "bench" (string-append (make-string 80 #\x) "\n" (make-string 4000 #\y)))])
    (do ([i 0 (fx+ i 1)]) ((fx= i 8))
      (buffers:add-span! (buffers:layer b responses) (fx+ 1 (fx* i 10)) (fx+ 6 (fx* i 10)) (list 'id i)))
    b))

;; The core queues saved data in a task posted after the batch, so joining
;; a task spawned after it includes the queueing. The core's writer thread
;; shares the one CPU the bench is pinned to, so wall time would charge
;; its printing to the main thread; the main thread's CPU time is what a
;; command waits for.
(define (thread-ns)
  (let ([t (current-time 'time-thread)])
    (+ (* (time-second t) 1000000000) (time-nanosecond t))))

(define (save-cost size)
  (fill-ring! size)
  (median
    (map (lambda (k)
           (collect-rendezvous)
           (let ([start (thread-ns)])
             (do ([i 0 (fx+ i 1)]) ((fx= i 20))
               (kill-ring:push! (list (make-string size #\z)))
               (batch-ended)
               (join-task (spawn-task void)))
             (/ (- (thread-ns) start) 20.)))
         (iota 9))))

(define (run)
  ;; An after-push entry, as a clipboard adds.
  (add-hook! kill-ring:after-push (lambda (entry) (set! copies (fx+ copies 1))))
  (fill-ring! 20)
  ;; A fresh line before each append and prepend, so the newest entry
  ;; stays a line long, as after one kill.
  (let ([push (ns-per-op 2000 (lambda () (kill-ring:push! (list line))))])
    (show "push" push)
    (show "append" (- (ns-per-op 2000 (lambda () (kill-ring:push! (list line)) (kill-ring:append! (list "x")))) push))
    (show "prepend" (- (ns-per-op 2000 (lambda () (kill-ring:push! (list line)) (kill-ring:prepend! (list "x")))) push)))
  (show "rotate" (ns-per-op 2000 (lambda () (kill-ring:rotate! 1))))
  (let* ([b (buffers:make "large" (make-string 1000000 #\l))]
         [p (buffers:piece b 1 (- (document:length (buffers:document b)) 1))])
    (with-options ([kill-ring:skip-duplicates #t])
      (show "push-large"
        (/ (ns-per-op 200 (lambda () (kill-ring:push! (list p)) (kill-ring:push! (list "small")))) 2))))
  (let* ([b (line-buffer)]
         [p (buffers:piece b 1 82)])
    (show "piece" (ns-per-op 2000 (lambda () (buffers:piece b 1 82))))
    ;; A view reads the document after each command, which freezes it, so
    ;; insert! reading it finds it frozen; without the read here, insert!
    ;; would be charged the freezing of the previous delete.
    (let-values ([(insert replace)
                  (ns-per-op-pair 2000
                    (lambda ()
                      (kill-ring:insert! b 83 p)
                      (buffers:replace! b 83 164 "")
                      (buffers:document b))
                    (lambda ()
                      (buffers:replace! b 83 83 p)
                      (buffers:replace! b 83 164 "")
                      (buffers:document b)))])
      (show "insert" insert)
      (show "replace" replace)
      (show "insert-overhead" (- insert replace))))
  (show "save-20" (save-cost 20))
  (show "save-200" (save-cost 200))
  (show "save-1000" (save-cost 1000))
  (show "save-4096" (save-cost 4096)))
