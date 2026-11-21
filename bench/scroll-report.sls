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

;; A page whose lines are 22 px high and 80 cells wide, showing the view
;; from line TOP of plain lines, where a line's slot is the line less
;; one, and asking for two view heights beyond each edge.
(define (make view client top height settled?)
  (let* ([html (html->string (views:draw view client))]
         [rows (quotient height 22)]
         [mark (lambda (line) (list (cons "line" line)))]
         [lines (+ (* 2 rows) 1)])
    `(("type" . "scroll") ("view" . ,(views:id view)) ("placement" . ,(%number-after html "data-placement=\""))
      ("report" . 1) ("version" . ,(%number-after html "data-version=\"")) ("slotVersion" . ,(%number-after html "data-slot-version=\"")) ("top" . ,(mark top)) ("spacer" . #f)
      ("fraction" . 0) ("left" . null) ("past" . 0) ("sides" . #()) ("start" . ,(mark top))
      ("end" . ,(mark (+ top rows -1))) ("atStart" . #f) ("atEnd" . #f) ("columns" . 80) ("rows" . ,rows)
      ("pointVisible" . #t) ("lost" . #f)
      ("wanted" . (("above" ("slot" . ,(max 0 (- top lines 1)))) ("below" ("slot" . ,(+ top rows lines -1))) ("side" . 160)))
      ("hand" . #t) ("settled" . ,settled?) ("edge" . "top"))))
