(import (tuna) (tuna plugins) (document) (haml) (web))
(use-plugin views
  (config
    (set-option! views:scroll-conservatively 20
                 views:wrap-lines #f)))

(define (show view) (display (html->string (views:draw view))) (newline))

(define (lines n)
  (let loop ([i n] [acc '()])
    (if (= i 0) (apply string-append acc) (loop (- i 1) (cons (format "line ~a\n" i) acc)))))

(define (search text needle from)
  (let ([n (string-length needle)])
    (let loop ([i from])
      (cond
        [(> (+ i n) (string-length text)) #f]
        [(string=? (substring text i (+ i n)) needle) i]
        [else (loop (+ i 1))]))))

(define (numbers-after text needle)
  (let loop ([from 0] [acc '()])
    (let ([i (search text needle from)])
      (if i
          (let digits ([j (+ i (string-length needle))] [k 0])
            (if (char-numeric? (string-ref text j))
                (digits (+ j 1) (+ (* k 10) (- (char->integer (string-ref text j)) 48)))
                (loop j (cons k acc))))
          (reverse acc)))))

(define (drawn view)
  (let* ([html (html->string (views:draw view))] [ls (numbers-after html "data-line=\"")])
    (list (car ls) (car (reverse ls)) (length ls)
          (numbers-after html "data-lines=\"") (numbers-after html "height:"))))

(define (placement view)
  (let ([html (html->string (views:draw view))])
    (list (car (numbers-after html "data-placement=\"")) (car (numbers-after html "data-place-line=\""))
          (let ([i (+ (search html "data-place-align=\"" 0) 18)])
            (string->symbol (substring html i (search html "\"" i)))))))

(define (report view placement top offset last height)
  ((table-ref web:input-handlers "scroll") 'client
   `(("type" . "scroll") ("view" . ,(views:id view)) ("placement" . ,placement)
     ("top" . ,top) ("offset" . ,offset) ("last" . ,last) ("height" . ,height))))

(define (line-of view p) (document:line (buffers:document (views:buffer view)) p))
(define (line-start view n) (document:line-start (buffers:document (views:buffer view)) n))
(import (console))
