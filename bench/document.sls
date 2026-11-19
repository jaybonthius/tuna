#!tuna
(import (document) (jobs))

(define (now-ns)
  (let ([t (current-time 'time-monotonic)])
    (+ (* (time-second t) 1000000000) (time-nanosecond t))))

(define (median xs)
  (list-ref (list-sort < xs) (quotient (length xs) 2)))

;; Text like source code: one word in fifty is not ASCII, so most runs
;; take the slower scans that non-ASCII text needs.
(define (sample-text megabytes)
  (let-values ([(port extract) (open-bytevector-output-port)])
    (let ([target (* megabytes 1000000)])
      (let loop ([size 0] [word 0])
        (if (>= size target)
            (extract)
            (let ([bytes (string->utf8
                           (string-append
                             (cond [(= (mod word 50) 0) "café"] [(= (mod word 50) 25) "λx"] [else "word"])
                             (if (= (mod word 9) 8) "\n" " ")))])
              (put-bytevector port bytes)
              (loop (+ size (bytevector-length bytes)) (+ word 1))))))))

(define batch 2000)

(define (randoms limit)
  (let ([v (make-vector batch)])
    (do ([i 0 (fx+ i 1)]) ((fx= i batch) v)
      (vector-set! v i (random limit)))))

(define (ns-per-op limit run)
  (median
    (map (lambda (k)
           (let ([args (randoms limit)])
             (collect-rendezvous)
             (let ([start (now-ns)])
               (run args)
               (/ (- (now-ns) start) (exact->inexact batch)))))
         (iota 9))))

(define (ms-per-mb megabytes thunk)
  (collect (collect-maximum-generation))
  (let ([start (now-ns)])
    (thunk)
    (/ (- (now-ns) start) 1e6 megabytes)))

(define (show name megabytes value)
  (printf "~a-~amb ~,2f\n" name megabytes value))

(define (bench megabytes)
  (let* ([bytes (sample-text megabytes)]
         [doc #f]
         [load (ms-per-mb megabytes (lambda () (set! doc (document:from-utf8 bytes))))]
         [doc (document:freeze doc jobs:freeze)]
         [size (document:length doc)]
         [lines (document:line doc size)]
         [one (document:from-datum "x")])
    (show "from-utf8" megabytes load)
    (let ([text (utf8->string bytes)])
      (set! bytes #f)
      (show "from-datum" megabytes (ms-per-mb megabytes (lambda () (document:from-datum text)))))
    (show "utf8-chunks" megabytes
      (ms-per-mb megabytes (lambda () (document:for-each-utf8-chunk doc 0 size (lambda (bv from to) to)))))
    (let ([insert (ns-per-op size
                    (lambda (ps)
                      (let loop ([i 0] [d doc])
                        (when (fx< i batch)
                          (let ([p (vector-ref ps i)])
                            (loop (fx+ i 1) (document:replace d p p one)))))))]
          [insert-freeze (ns-per-op size
                           (lambda (ps)
                             (let loop ([i 0] [d doc])
                               (when (fx< i batch)
                                 (let ([p (vector-ref ps i)])
                                   (loop (fx+ i 1) (document:freeze (document:replace d p p one) jobs:freeze)))))))])
      (show "insert" megabytes insert)
      (show "snapshot" megabytes (- insert-freeze insert)))
    (show "line" megabytes
      (ns-per-op size (lambda (ps) (vector-for-each (lambda (p) (document:line doc p)) ps))))
    (show "line-start" megabytes
      (ns-per-op lines (lambda (ls) (vector-for-each (lambda (l) (document:line-start doc (+ l 1))) ls))))
    (show "char-offset" megabytes
      (ns-per-op size (lambda (ps) (vector-for-each (lambda (p) (document:offset doc p (document:unit characters))) ps))))
    (show "char-position" megabytes
      (let ([chars (document:offset doc size (document:unit characters))])
        (ns-per-op chars (lambda (cs) (vector-for-each (lambda (c) (document:position doc c (document:unit characters))) cs)))))
    (show "token" megabytes
      (ns-per-op size (lambda (ps) (vector-for-each (lambda (p) (document:token doc p)) ps))))))

(define list-rows 3880000)

(define (bench-repeat)
  (let ([row (document:from-datum '#(row ((generation . 1))))])
    (printf "repeat-rows ~,3f\n"
      (median
        (map (lambda (k)
               (collect-rendezvous)
               (let ([start (now-ns)])
                 (document:repeat row list-rows)
                 (/ (- (now-ns) start) 1e6)))
             (iota 9))))
    (printf "repeat-rows-size ~,2f\n" (/ (compute-size (document:repeat row list-rows)) 1000.))))

(define (run)
  (random-seed 7)
  (for-each bench '(1 10 100))
  (bench-repeat))
