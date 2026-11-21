(library (sample)
  (export area)
  (import (chezscheme))

  ;; A comment
  (define-record-type point (fields x y))

  (define (area r)
    (let ([sq (* r r)])
      (display "area\n")
      (if (null? (list sq)) #f (car (list (* 3.14 sq)))))))
