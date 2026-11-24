(import (tuna) (testing) (jobs) (document) (document-checks) (buffers) (long-lines))

(define (at doc text)
  (let* ([all (document:text doc)] [n (string-length text)])
    (let loop ([i 0])
      (if (string=? (substring all i (+ i n)) text)
          (- (document:position doc (+ i n 1) (document:unit characters)) 1)
          (loop (+ i 1))))))

(import (console))
