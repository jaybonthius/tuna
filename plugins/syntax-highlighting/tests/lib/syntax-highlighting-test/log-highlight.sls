(library (syntax-highlighting-test log-highlight)
  (export highlight)
  (import (chezscheme) (document))

  (define (line-end text i n)
    (cond
      [(fx= i n) n]
      [(char=? (string-ref text i) #\newline) (fx+ i 1)]
      [else (line-end text (fx+ i 1) n)]))

  (define (highlight document comment-face edits)
    (let* ([text (document:text document)] [n (string-length text)])
      (let loop ([start 0] [spans '()])
        (if (fx= start n)
            (values (list (list->vector (reverse spans))) #f)
            (let ([end (line-end text start n)])
              (loop end
                    (if (char=? (string-ref text start) #\#)
                        (cons (list start end (list (cons 'face comment-face))) spans)
                        spans))))))))
