#!tuna
(import (document) (buffers) (views) (haml))

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

(define (%has? html name)
  (let ([n (string-length name)])
    (let search ([k 0])
      (cond [(> (+ k n) (string-length html)) #f]
            [(string=? (substring html k (+ k n)) name) #t]
            [else (search (+ k 1))]))))

(define (%drawn-screens html)
  (let* ([name "data-drawn-screens=\""] [n (string-length name)])
    (let search ([k 0])
      (if (string=? (substring html k (+ k n)) name)
          (let end ([j (+ k n)])
            (if (char=? (string-ref html j) #\")
                (string->number (substring html (+ k n) j))
                (end (+ j 1))))
          (search (+ k 1))))))

(define (make view client top height settled?)
  (let* ([html (html->string (views:draw view client))] [lines (lines-drawn html)]
         [last (car (reverse lines))]
         [rows (quotient height 22)] [columns (quotient 800 9)]
         [bottom (+ top rows -1)]
         [doc (buffers:document (views:buffer view))]
         [point-line (document:line doc (views:point view))]
         [mark (lambda (line) (list (cons "line" line)))]
         [wanted-lines (+ (exact (ceiling (/ (* (%drawn-screens html) height) 22))) 1)])
    `(("type" . "scroll") ("view" . ,(views:id view)) ("placement" . ,(%number-after html "data-placement=\""))
      ("report" . 1) ("version" . ,(%number-after html "data-version=\""))
      ("top" . ,(mark top)) ("spacer" . ,(not (memv top lines))) ("fraction" . 0)
      ("left" . ,(mark top)) ("past" . 0) ("sides" . #())
      ("start" . ,(mark top)) ("end" . ,(mark bottom))
      ("atStart" . ,(and (%has? html "data-run-at-start") (= top 1)))
      ("atEnd" . ,(and (%has? html "data-run-at-end") (not (%has? html "data-spacer=\"below\"")) (>= bottom last)))
      ("columns" . ,columns) ("rows" . ,rows) ("pointVisible" . ,(<= top point-line bottom)) ("lost" . #f)
      ("wanted" . (("aboveLines" . ,wanted-lines) ("aboveChars" . ,(* wanted-lines columns))
                   ("belowLines" . ,wanted-lines) ("belowChars" . ,(* wanted-lines columns))
                   ("side" . ,(exact (ceiling (* (%drawn-screens html) columns))))))
      ("hand" . #f) ("settled" . ,settled?) ("edge" . "top"))))
