(import (test) (plain-data))

(define (cpu-seconds thunk)
  (let ([start (cpu-time)])
    (thunk)
    (/ (- (cpu-time) start) 1000.)))

(define (not-plain? c)
  (and (assertion-violation? c) (eq? (condition-who c) 'copier)
       (equal? (condition-message c) "not plain data")))

(test "numbers, characters, strings, symbols, booleans, bytevectors, the empty list, pairs and vectors are plain data"
  (check (for-all plain-data:plain-data?
           (list 1 1/2 1.5 (expt 10 30) #\a "s" 's #t #f (bytevector 1) '() (cons 1 2) (vector 1 "v")))))

(test "a long list, and a deep one, are plain data"
  (check (plain-data:plain-data? (iota 1000000)))
  (check (plain-data:plain-data? (let loop ([i 0] [v '()]) (if (= i 100000) v (loop (+ i 1) (list v)))))))

(test "a cycle anywhere is found"
  (let ([long (iota 100000)])
    (set-cdr! (last-pair long) (list-tail long 50000))
    (check (not (plain-data:plain-data? long))))
  (let ([v (make-vector 3 1)])
    (vector-set! v 2 (list 1 (vector 2 v)))
    (check (not (plain-data:plain-data? (list 'a v)))))
  (let ([p (list 1 2)])
    (set-car! (cdr p) p)
    (check (not (plain-data:plain-data? (vector p))))))

(test "shared structure is walked once"
  (let ([dag (let loop ([i 0] [v '()]) (if (= i 1000) v (loop (+ i 1) (vector v v))))])
    (check (< (cpu-seconds (lambda () (check (plain-data:plain-data? dag)))) 0.5))))

(test "a value inside plain structure that is not plain data is found"
  (check (not (plain-data:plain-data? (list 1 2 (vector 3 (list 4 (box 5)))))))
  (check (not (plain-data:plain-data? (cons 1 car))))
  (check (not (plain-data:plain-data? (list (string->symbol "s") (make-record-type-descriptor 'r #f #f #f #f '#()))))))

(test "a copy is equal and shares no mutable object with the original"
  (let* ([fixed (string->immutable-string "fixed")]
         [fixed-bytes (bytevector->immutable-bytevector (bytevector 1 2))]
         [v (list (string-copy "text") fixed (bytevector 3) fixed-bytes (vector 'a 1/2 #\x) 12345678901234567890 '())]
         [c (plain-data:copy 'copier v)])
    (check-equal? v c)
    (check (not (eq? v c)))
    (check (not (eq? (list-ref v 4) (list-ref c 4))))
    (check (immutable-string? (car c)))
    (check (eq? fixed (cadr c)))
    (check (immutable-bytevector? (caddr c)))
    (check (eq? fixed-bytes (cadddr c)))
    (check-equal? "text" (plain-data:copy 'copier "text"))
    (check-equal? 5 (plain-data:copy 'copier 5))
    (check-equal? #f (plain-data:copy 'copier #f))))

(test "a copy keeps shared structure shared"
  (let* ([s (string-copy "shared")] [p (list s s)] [w (vector p p)]
         [c (plain-data:copy 'copier (list w w p))])
    (check (eq? (car c) (cadr c)))
    (check (eq? (vector-ref (car c) 0) (caddr c)))
    (check (eq? (car (caddr c)) (cadr (caddr c)))))
  (let* ([tail (list 1 2)] [c (plain-data:copy 'copier (list (cons 'a tail) (cons 'b tail)))])
    (check (eq? (cdar c) (cdadr c))))
  (let ([dag (let loop ([i 0] [x '()]) (if (= i 40) x (loop (+ i 1) (cons x x))))])
    (check (< (cpu-seconds (lambda () (let ([c (plain-data:copy 'copier dag)]) (check (eq? (car c) (cdr c)))))) 0.5))))

(test "a long list, and a deep one, are copied"
  (check-equal? 999999 (car (last-pair (plain-data:copy 'copier (iota 1000000)))))
  (let ([deep (let loop ([i 0] [v '()]) (if (= i 100000) v (loop (+ i 1) (list v))))])
    (check-equal? deep (plain-data:copy 'copier deep))))

(test "a copy refuses a cycle, or a value that is not plain data"
  (let ([long (iota 1000)])
    (set-cdr! (last-pair long) (list-tail long 500))
    (check-raises not-plain? (plain-data:copy 'copier long)))
  (let ([v (make-vector 3 1)])
    (vector-set! v 2 (list 1 (vector 2 v)))
    (check-raises not-plain? (plain-data:copy 'copier (list 'a v))))
  (let ([p (list 1 2)])
    (set-car! (cdr p) p)
    (check-raises not-plain? (plain-data:copy 'copier (vector p))))
  (check-raises not-plain? (plain-data:copy 'copier (list 1 2 (vector 3 (list 4 (box 5))))))
  (check-raises not-plain? (plain-data:copy 'copier car)))

(test "procedures, hashtables, boxes, fxvectors and the void object are not plain data, nor is anything holding one"
  (check-equal? '(#f #f #f #f #f #f #f)
    (map plain-data:plain-data? (list car (make-eq-hashtable) (box 1) (fxvector 1) (void) (list 1 car) (vector (box 1))))))
