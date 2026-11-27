(library (syntax characters)
  (export holds-char? word-char? symbol-char? word-char-predicate)
  (import (chezscheme))

  (define (holds-char? s c)
    (let ([n (string-length s)])
      (let loop ([i 0])
        (and (fx< i n) (or (char=? (string-ref s i) c) (loop (fx+ i 1)))))))

  (define (word-char? c words)
    (or (char-alphabetic? c) (char-numeric? c) (holds-char? words c)))

  (define (symbol-char? c words symbols)
    (or (word-char? c words) (holds-char? symbols c)))

  ;; A scan of a whole buffer asks for every character, so the answers
  ;; for ASCII are looked up rather than searched for in the string.
  (define (word-char-predicate words)
    (let ([ascii (make-bytevector 128 0)])
      (do ([i 0 (fx+ i 1)]) ((fx= i 128))
        (when (word-char? (integer->char i) words)
          (bytevector-u8-set! ascii i 1)))
      (lambda (c)
        (let ([n (char->integer c)])
          (if (fx< n 128)
              (fx= (bytevector-u8-ref ascii n) 1)
              (word-char? c words)))))))
