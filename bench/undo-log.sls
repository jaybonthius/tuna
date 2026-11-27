#!tuna
(import (undo-log) (undo-log disk) (undo) (files) (buffers) (document) (options) (timers))

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

(define folder (string-append (getenv "HOME") "/files"))

(define (path name) (string-append folder "/" name))

(define (write-text! file text)
  (call-with-port (open-file-output-port file (file-options no-fail))
    (lambda (p) (put-bytevector p (string->utf8 text)))))

(define (wait-for-log file size)
  (let loop ([n 0])
    (unless (or (and (file-exists? file) (>= (call-with-port (open-file-input-port file) port-length) size))
                (= n 3000))
      (timers:sleep 0.01)
      (loop (+ n 1)))))

;; undo-log keeps its log folder private, so a benchmark reads it in
;; undo-log's scope.
(define (log-of file) (string-append ((eval-in-module '%log-folder '(undo-log))) file ".ss"))

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

(define (batch-end-cost)
  (let* ([file (path "batch.txt")] [_ (write-text! file "batch\n")] [b (files:visit file)]
         [kept (buffers:make "kept-batch" "\n")])
    (cpu-ns-difference 300
      (lambda () (buffers:replace! b 1 1 "x") (batch-ended))
      (lambda () (buffers:replace! kept 1 1 "x") (batch-ended)))))

(define (typing-log file)
  (write-text! file "typing\n")
  (let ([b (files:visit file)])
    (let loop ([i 0])
      (unless (and (file-exists? (log-of file))
                   (>= (call-with-port (open-file-input-port (log-of file)) port-length) 1000000))
        (buffers:replace! b 1 1 (string (integer->char (+ 97 (mod i 26)))))
        (timers:sleep 0)
        (loop (+ i 1))))
    (buffers:kill! b)
    (timers:sleep 0.5)))

(define (run)
  (mkdir folder)
  (options:set! undo-log:keep-log? (lambda (path) #t))
  (show "log-batch-end-ns" (batch-end-cost))
  (let ([file (path "typing.txt")])
    (typing-log file)
    (let ([log (log-of file)])
      (let-values ([(records torn?) (read-log log)])
        (let ([n (length records)] [size (call-with-port (open-file-input-port log) port-length)])
          (show "read-log-ms-per-mb"
            (/ (median (map (lambda (i) (let ([start (now-ns)]) (read-log log) (- (now-ns) start))) (iota 5)))
               1e6 (/ size 1e6)))
          (let* ([visit (median (map (lambda (i)
                                       (let ([start (thread-cpu-ns)])
                                         (buffers:kill! (files:visit file))
                                         (- (thread-cpu-ns) start)))
                                     (iota 5)))]
                 [plain (begin
                          (options:set! undo-log:keep-log? (lambda (path) #f))
                          (median (map (lambda (i)
                                         (let ([start (thread-cpu-ns)])
                                           (buffers:kill! (files:visit file))
                                           (- (thread-cpu-ns) start)))
                                       (iota 5))))])
            (options:set! undo-log:keep-log? (lambda (path) #t))
            (show "replay-ns-per-record" (/ (- visit plain) n)))))))
  (let ([file (path "round.txt")] [bytes (records->bytes (list '(at 1)))])
    (show "writer-round-ms"
      (median (map (lambda (i) (let ([start (now-ns)]) (append-log! file bytes) (/ (- (now-ns) start) 1e6)))
                   (iota 9))))))
