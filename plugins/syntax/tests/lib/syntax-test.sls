#!tuna
(import (buffers) (document) (syntax))

(define (lexeme->list l) (list (syntax:lexeme-class l) (syntax:lexeme-start l) (syntax:lexeme-end l) (syntax:lexeme-depth l)))

(define (text b) (document:text (buffers:document b)))

(define (%index b string)
  (let* ([all (text b)] [n (string-length string)])
    (let loop ([i 0])
      (if (string=? (substring all i (+ i n)) string)
          i
          (loop (+ i 1))))))

(define (after b string)
  (document:position (buffers:document b) (+ (%index b string) (string-length string)) (document:unit characters)))

(define (before b string)
  (- (document:position (buffers:document b) (+ (%index b string) 1) (document:unit characters)) 1))

(define (between b start end) (document:text (buffers:document b) start end))
