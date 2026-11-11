(import (chezscheme) (tuna-test) (tuna plain-data))

(define (cpu-seconds thunk)
  (let ([start (cpu-time)])
    (thunk)
    (/ (- (cpu-time) start) 1000.)))

(test "a long list, and a deep one, are plain data"
  (check (plain-data? (iota 1000000)))
  (check (plain-data? (let loop ([i 0] [v '()]) (if (= i 100000) v (loop (+ i 1) (list v)))))))

(test "a cycle anywhere is found"
  (let ([long (iota 100000)])
    (set-cdr! (last-pair long) (list-tail long 50000))
    (check (not (plain-data? long))))
  (let ([v (make-vector 3 1)])
    (vector-set! v 2 (list 1 (vector 2 v)))
    (check (not (plain-data? (list 'a v)))))
  (let ([p (list 1 2)])
    (set-car! (cdr p) p)
    (check (not (plain-data? (vector p))))))

(test "shared structure is walked once"
  (let ([dag (let loop ([i 0] [v '()]) (if (= i 1000) v (loop (+ i 1) (vector v v))))])
    (check (< (cpu-seconds (lambda () (check (plain-data? dag)))) 0.5))))

(test "a value inside plain structure that is not plain data is found"
  (check (not (plain-data? (list 1 2 (vector 3 (list 4 (box 5)))))))
  (check (not (plain-data? (cons 1 car))))
  (check (not (plain-data? (list (string->symbol "s") (make-record-type-descriptor 'r #f #f #f #f '#()))))))

(test-exit)
