(library (jobs-test words)
  (export word-count)
  (import (chezscheme))

  (define (word-count text)
    (let loop ([i 0] [in-word? #f] [n 0])
      (if (= i (string-length text))
          n
          (let ([space? (char=? (string-ref text i) #\space)])
            (loop (+ i 1) (not space?) (if (or space? in-word?) n (+ n 1))))))))
