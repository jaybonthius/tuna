#!tuna
(import (views) (haml))

(define (%number-after html name)
  (let ([n (string-length name)])
    (let search ([k 0])
      (if (string=? (substring html k (+ k n)) name)
          (let digits ([k (+ k n)] [v 0])
            (if (char-numeric? (string-ref html k))
                (digits (+ k 1) (+ (* v 10) (- (char->integer (string-ref html k)) 48)))
                v))
          (search (+ k 1))))))

(define (lines-drawn html)
  (let loop ([i 0] [acc '()])
    (let ([j (let search ([k i])
               (cond [(> (+ k 11) (string-length html)) #f]
                     [(string=? (substring html k (+ k 11)) "data-line=\"") k]
                     [else (search (+ k 1))]))])
      (if j
          (let digits ([k (+ j 11)] [n 0])
            (if (char-numeric? (string-ref html k))
                (digits (+ k 1) (+ (* n 10) (- (char->integer (string-ref html k)) 48)))
                (loop k (cons n acc))))
          (reverse acc)))))

(define (make view client top height settled?)
  (let* ([html (html->string (views:draw view client))] [lines (lines-drawn html)]
         [last (car (reverse lines))]
         [mark (lambda (line) (list (cons "line" line)))])
    `(("type" . "scroll") ("view" . ,(views:id view)) ("placement" . ,(%number-after html "data-placement=\""))
      ("report" . 1) ("version" . ,(%number-after html "data-version=\"")) ("top" . ,(mark top)) ("offset" . 0)
      ("itemHeight" . 22) ("left" . 0) ("start" . ,(mark top)) ("end" . ,(mark (+ top (quotient height 22) -1)))
      ("spacer" . null) ("spacerDistance" . 0) ("below" . ,(max 0 (- (* 22 (+ 1 (- last top))) height)))
      ("items" . ,(list->vector (map (lambda (line) (vector (mark line) 22)) lines)))
      ("lineHeight" . 22) ("charWidth" . 9) ("width" . 800) ("height" . ,height) ("settled" . ,settled?) ("hand" . #f)
      ("runAtEnd" . #f))))
