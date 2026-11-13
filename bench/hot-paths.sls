#!tuna
(import (bench-callee))

(define-option column 70 fixnum?)
(define-hook other10)
(define-hook same10)
(define-hook other1)
(define-hook changed)
(define-table keys)
(define-table procedures)

(define (now-ns)
  (let ([t (current-time 'time-monotonic)])
    (+ (* (time-second t) 1000000000) (time-nanosecond t))))

(define (median xs)
  (list-ref (list-sort < xs) (quotient (length xs) 2)))

(define (ns-per run n)
  (collect-rendezvous)
  (let ([start (now-ns)])
    (run n)
    (/ (- (now-ns) start) (exact->inexact n))))

;; The loop alone is timed too and taken away, so that a result is the
;; operation's own cost.
(define (measure-against label n divisor base run)
  (let loop ([k 0] [ops '()] [bases '()])
    (if (= k 9)
        (printf "~a ~,2f\n" label (/ (- (median ops) (median bases)) divisor))
        (let* ([base-ns (ns-per base n)] [op (ns-per run n)])
          (loop (+ k 1) (cons op ops) (cons base-ns bases))))))

(define (measure label n divisor run)
  (measure-against label n divisor base-loop run))

(define (base-loop n)
  (let loop ([i 0] [acc 0]) (if (fx= i n) acc (loop (fx+ i 1) (fx+ acc 1)))))

(define (entries n) (map (lambda (k) (lambda (i) (fx+ i k))) (iota n)))

(define (entry i) i)

(define (fill-table!)
  (for-each
    (lambda (i)
      (table-set! keys (string->symbol (format "k~a" i)) 1)
      (table-set! keys (format "s~a" i) 1)
      (table-set! keys (list 'C-c (integer->char (+ 97 (mod i 26))) i) 1))
    (iota 100))
  (table-set! keys #\a 1))

;; Equal-hash gives every procedure one hash, so a thousand of them is
;; where a table that hashed them so would search the longest.
(define procedure-keys (list->vector (map (lambda (i) (lambda () i)) (iota 1000))))

(define (fill-procedures!)
  (vector-for-each (lambda (p) (table-set! procedures p 1)) procedure-keys))

(define (calls)
  (measure "changeable-call" 20000000 1
    (lambda (n) (let loop ([i 0] [acc 0]) (if (fx= i n) acc (loop (fx+ i 1) (bench-callee:add1 acc)))))))

(define (options)
  (measure "option-read" 20000000 1
    (lambda (n) (let loop ([i 0] [acc 0]) (if (fx= i n) acc (loop (fx+ i 1) (fx+ acc (column)))))))
  (with-options ([column 5])
    (measure "option-read-bound" 20000000 1
      (lambda (n) (let loop ([i 0] [acc 0]) (if (fx= i n) acc (loop (fx+ i 1) (fx+ acc (column))))))))
  (measure "with-options" 5000000 1
    (lambda (n)
      (let loop ([i 0] [acc 0])
        (if (fx= i n) acc (loop (fx+ i 1) (with-options ([column i]) (fx+ acc 1)))))))
  (let ([s (make-scope)])
    (parameterize ([current-scope s])
      (set-option-local! column 100)
      (measure "option-read-local" 20000000 1
        (lambda (n) (let loop ([i 0] [acc 0]) (if (fx= i n) acc (loop (fx+ i 1) (fx+ acc (column)))))))
      (remove-option-local! column))))

(define (hooks)
  (as-module '(init)
    (for-each (lambda (p) (add-hook! same10 p)) (entries 10)))
  (measure "hook-entry-other" 1000000 10
    (lambda (n) (let loop ([i 0]) (unless (fx= i n) (other10 i) (loop (fx+ i 1))))))
  (measure "hook-entry-same" 1000000 10
    (lambda (n) (let loop ([i 0]) (unless (fx= i n) (same10 i) (loop (fx+ i 1))))))
  (measure "hook-one-entry-other" 5000000 1
    (lambda (n) (let loop ([i 0]) (unless (fx= i n) (other1 i) (loop (fx+ i 1)))))))

;; Each lookup takes the next of 64 keys, so that one key's place in the
;; hashtable does not decide the result; the base loop picks keys too.
(define (key-loop keys)
  (lambda (n)
    (let loop ([i 0] [acc 0])
      (if (fx= i n) acc (loop (fx+ i 1) (fx+ acc (if (vector-ref keys (fxand i 63)) 1 0)))))))

(define (tables)
  (fill-table!)
  (let ([symbols (vector-map (lambda (i) (string->symbol (format "k~a" i))) (list->vector (iota 64)))]
        [strings (vector-map (lambda (i) (format "s~a" i)) (list->vector (iota 64)))])
    (measure-against "table-ref-symbol" 5000000 1 (key-loop symbols)
      (lambda (n)
        (let loop ([i 0] [acc 0])
          (if (fx= i n) acc (loop (fx+ i 1) (fx+ acc (table-ref keys (vector-ref symbols (fxand i 63)) 0)))))))
    (measure-against "table-ref-string" 5000000 1 (key-loop strings)
      (lambda (n)
        (let loop ([i 0] [acc 0])
          (if (fx= i n) acc (loop (fx+ i 1) (fx+ acc (table-ref keys (vector-ref strings (fxand i 63)) 0))))))))
  (fill-procedures!)
  (measure-against "table-ref-procedure" 5000000 1 (key-loop procedure-keys)
    (lambda (n)
      (let loop ([i 0] [acc 0])
        (if (fx= i n) acc (loop (fx+ i 1) (fx+ acc (table-ref procedures (vector-ref procedure-keys (fxand i 63)) 0))))))))

(define (changes)
  (as-module '(init)
    (for-each (lambda (p) (add-hook! changed p)) (entries 10))
    (measure "table-set!" 20000 1
      (lambda (n) (let loop ([i 0]) (unless (fx= i n) (table-set! keys #\a i) (loop (fx+ i 1))))))
    (measure "set-option!" 20000 1
      (lambda (n) (let loop ([i 0]) (unless (fx= i n) (set-option! column (fx+ 60 (fxand i 7))) (loop (fx+ i 1))))))
    (measure "add-hook!-remove-hook!" 20000 1
      (lambda (n)
        (let loop ([i 0])
          (unless (fx= i n) (add-hook! changed entry) (remove-hook! changed entry) (loop (fx+ i 1))))))))

(define (spawn-tasks n)
  (collect-rendezvous)
  (let ([start (now-ns)])
    (suspend
      (lambda (resume)
        (let ([left n])
          (do ([i 0 (+ i 1)]) ((= i n))
            (spawn-task (lambda () (set! left (- left 1)) (when (= left 0) (resume void))))))))
    (/ (- (now-ns) start) (exact->inexact n))))

(define (tasks)
  (printf "spawn-task-20000 ~,2f\n" (median (map (lambda (k) (spawn-tasks 20000)) (iota 5)))))

(define (bytes-allocated-so-far)
  (sstats-bytes (statistics)))

;; Every event handed to the main thread pays this, and what it allocates
;; decides how often a burst of events makes the collector run.
(define (posted-item-bytes n)
  (let ([start (bytes-allocated-so-far)])
    (suspend
      (lambda (resume)
        (do ([i 0 (+ i 1)]) ((= i n)) (post! void))
        (post! (lambda () (resume void)))))
    (/ (- (bytes-allocated-so-far) start) (exact->inexact n))))

(define (posts)
  (printf "posted-item-bytes ~,2f\n" (median (map (lambda (k) (posted-item-bytes 100000)) (iota 5)))))

(define (run)
  (calls)
  (options)
  (hooks)
  (tables)
  (changes)
  (tasks)
  (posts))

(for-each (lambda (p) (add-hook! other10 p)) (entries 10))
(add-hook! other1 (car (entries 1)))
