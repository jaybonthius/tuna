#!tuna
(import (undo) (undo log) (files) (buffers) (document))

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
      (sleep-for 0.01)
      (loop (+ n 1)))))

(define (log-of file) (string-append (undo:%log-folder) file ".ss"))

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
  (let* ([file (path "batch.txt")] [_ (write-text! file "batch\n")] [b (files:visit file)]
         [plain (buffers:make "plain-batch" "\n")])
    (buffers:with-buffer plain (set-option-local! undo:limit 0))
    (- (cpu-ns-difference 300
         (lambda () (buffers:replace! b 1 1 "x") (batch-ended))
         (lambda () (buffers:replace! plain 1 1 "x") (batch-ended)))
       record)))

(define (move-cost)
  (let ([b (buffers:make "moves" (make-string 100000 #\m))])
    (buffers:replace! b 50000 50000 "word ")
    (batch-ended)
    (let ([id (car (undo:history b))])
      (/ (cpu-ns-per-op 1000 (lambda () (undo:go-to! b 0) (undo:go-to! b id))) 2.0))))

(define (typing-log file)
  (write-text! file "typing\n")
  (let ([b (files:visit file)])
    (let loop ([i 0])
      (unless (and (file-exists? (log-of file))
                   (>= (call-with-port (open-file-input-port (log-of file)) port-length) 1000000))
        (buffers:replace! b 1 1 (string (integer->char (+ 97 (mod i 26)))))
        (sleep-for 0)
        (loop (+ i 1))))
    (buffers:kill! b)
    (sleep-for 0.5)))

(define (run)
  (mkdir folder)
  (set-option! undo:keep-log? (lambda (path) #t))
  (let ([record (record-cost)])
    (show "record-ns" record)
    (show "batch-end-ns" (batch-end-cost record)))
  (show "undo-step-us" (/ (move-cost) 1000.0))
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
                          (set-option! undo:keep-log? (lambda (path) #f))
                          (median (map (lambda (i)
                                         (let ([start (thread-cpu-ns)])
                                           (buffers:kill! (files:visit file))
                                           (- (thread-cpu-ns) start)))
                                       (iota 5))))])
            (set-option! undo:keep-log? (lambda (path) #t))
            (show "replay-ns-per-record" (/ (- visit plain) n)))))))
  (let ([file (path "round.txt")] [bytes (records->bytes (list '(at 1)))])
    (show "writer-round-ms"
      (median (map (lambda (i) (let ([start (now-ns)]) (append-log! file bytes) (/ (- (now-ns) start) 1e6)))
                   (iota 9))))))
