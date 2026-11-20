#!tuna
(import (files) (files disk) (buffers) (document))

;; The main thread's own processor time, so a job's work on its thread is
;; left out.
(define (thread-ns)
  (let ([t (current-time 'time-thread)])
    (+ (* (time-second t) 1000000000) (time-nanosecond t))))

(define (now-ns)
  (let ([t (current-time 'time-monotonic)])
    (+ (* (time-second t) 1000000000) (time-nanosecond t))))

(define (median xs)
  (list-ref (list-sort < xs) (quotient (length xs) 2)))

(define (show name value)
  (printf "~a ~,2f\n" name value))

(define folder (string-append (getenv "HOME") "/files"))

(define (path name) (string-append folder "/" name))

(define (megabyte)
  (let-values ([(out extract) (open-string-output-port)])
    (let loop ([i 0])
      (when (< (port-position out) 1000000)
        (fprintf out "  (define (helper-~a x) (string-append \"caf\xE9; \" (number->string (* x ~a))))\n" i i)
        (loop (+ i 1))))
    (string->utf8 (extract))))

(define (write-bytes! file bytes)
  (call-with-port (open-file-output-port file (file-options no-fail))
    (lambda (p) (put-bytevector p bytes))))

(define (job-ms thunk)
  (median (map (lambda (i) (let ([start (now-ns)]) (thunk) (/ (- (now-ns) start) 1e6))) (iota 9))))

;; The least sample, since other processes' memory traffic only adds time.
(define (main-us thunk)
  (apply min
    (map (lambda (i)
           (collect-rendezvous)
           (let ([start (thread-ns)]) (thunk) (/ (- (thread-ns) start) 1e3)))
         (iota 31))))

(define (ns-per-op thunk)
  (median
    (map (lambda (k)
           (collect-rendezvous)
           (let ([start (now-ns)])
             (do ([i 0 (fx+ i 1)]) ((fx= i 2000)) (thunk))
             (/ (- (now-ns) start) 2000.0)))
         (iota 9))))

(define (run)
  (mkdir folder)
  (let ([bytes (megabyte)] [file (path "big.ss")])
    (write-bytes! file bytes)
    (show "read-1mb-job-ms" (job-ms (lambda () (read-file file))))
    (show "visit-1mb-main-us"
      (main-us (lambda () (buffers:kill! (files:visit file)))))
    (let ([b (files:visit file)])
      (show "visit-open-us" (main-us (lambda () (files:visit file))))
      (show "modified?-ns" (ns-per-op (lambda () (buffers:modified? b))))
      (let ([doc (buffers:document b)])
        (show "save-1mb-job-ms"
          (job-ms (lambda () (save-file (path "copy.ss") doc #f #f 0 fnv-basis #f)))))
      (show "save-1mb-main-us"
        (main-us (lambda () (buffers:replace! b 1 1 ";") (files:save-buffer b))))
      (let ([middle (quotient (bytevector-length bytes) 2)])
        (show "revert-1mb-main-us"
          (median
            (map (lambda (i)
                   (bytevector-u8-set! bytes middle (if (= (bytevector-u8-ref bytes middle) 120) 121 120))
                   (write-bytes! file bytes)
                   (let ([start (thread-ns)])
                     (files:revert-from-file b)
                     (/ (- (thread-ns) start) 1e3)))
                 (iota 9))))))))
