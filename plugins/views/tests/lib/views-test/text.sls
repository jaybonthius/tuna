#!tuna
(import (buffers) (document) (views))

(define (lines n)
  (apply string-append (map (lambda (i) (format "line ~a\n" (+ i 1))) (iota n))))

(define (line-of view position)
  (document:line (buffers:document (views:buffer view)) position))

(define (line-start view line)
  (document:line-start (buffers:document (views:buffer view)) line))
