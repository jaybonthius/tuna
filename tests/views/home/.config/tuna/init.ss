(import (tuna) (tuna plugins) (document) (haml) (web))
(use-plugin views
  (config
    (set-option! views:scroll-margin 2
                 views:wrap-lines #f)))

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

(define (word-after text needle)
  (let ([i (search text needle 0)])
    (and i (let ([from (+ i (string-length needle))])
             (string->symbol (substring text from (search text "\"" from)))))))

(define (without-placement html)
  (let loop ([html html] [from 0])
    (let ([i (search html "data-placement=\"" from)])
      (if i
          (let ([end (search html "\"" (+ i 16))])
            (loop (string-append (substring html 0 (+ i 16)) "*" (substring html end (string-length html))) (+ i 17)))
          html))))

(define (show view) (display (without-placement (html->string (views:draw view #f)))) (newline))

(define desktop (web:make-client 1))
(define phone (web:make-client 2))
(define (height-of client) (if (eq? client phone) 200 400))

(define (html-of view client) (html->string (views:draw view client)))

;; The first, last and count of lines drawn, and the lines each spacer
;; stands for, above and below.
(define (drawn view client)
  (let* ([html (html-of view client)] [ls (map car (line-marks html))])
    (define (spacer side)
      (let ([i (search html (string-append "data-spacer=\"" side "\"") 0)])
        (if i (list (car (numbers-after (substring html i (search html ">" i)) "data-lines=\""))) '())))
    (list (car ls) (car (reverse ls)) (length ls) (spacer "above") (spacer "below"))))

(define seen '())

(define (placement view client)
  (let* ([html (html-of view client)] [n (car (numbers-after html "data-placement=\""))]
         [key (cons (views:id view) (web:client-number client))] [last (assoc key seen)]
         [kind (word-after html "data-place-kind=\"")]
         [at (let ([item (numbers-after html "data-place-item=\"")] [at (numbers-after html "data-place-at=\"")])
               (cond [(and (memq kind '(top center bottom)) (pair? at)) (car at)] [(pair? item) (car item)] [else #f]))])
    (set! seen (cons (cons key n) seen))
    (list (if (and last (= (cdr last) n)) 'same 'new) kind (and at (line-of view at)))))

(define reports 0)

(define (line-marks html)
  (let loop ([from 0] [acc '()])
    (let ([i (search html "<div class=\"line\"" from)])
      (if i
          (let* ([close (search html ">" i)] [tag (substring html i close)]
                 [line (car (numbers-after tag "data-line=\""))]
                 [at (let ([a (numbers-after tag "data-at=\"")]) (and (pair? a) (car a)))])
            (loop close (cons (cons line (if at (list (cons "at" at)) (list (cons "line" line)))) acc)))
          (reverse acc)))))

;; Stands for the page of a view that does not wrap, each line 20 px:
;; TOP is the line at the top edge and OFFSET the px of it above the
;; edge. A line that is not drawn lies in a spacer, which names it by
;; its counts, a line per row. The first and last lines wholly in view
;; keep the configuration's scroll margin of 2 lines from the edges.
(define (report! client view top offset settled? . overrides)
  (let* ([html (html-of view client)]
         [marks (line-marks html)]
         [h (height-of client)]
         [spacer? (not (assv top marks))]
         [whole-from (+ (if (> offset 0.5) (+ top 1) top) 2)]
         [whole-to (- (+ top (quotient (+ h offset) 20)) 1 2)]
         [mark (lambda (line) (or (cdr (or (assv line marks) '(#f . #f))) (list (cons "line" line))))])
    (set! reports (+ reports 1))
    ((table-ref web:input-handlers "scroll") client
     (map (lambda (field) (or (assoc (car field) overrides) field))
     `(("type" . "scroll") ("view" . ,(views:id view))
       ("placement" . ,(car (numbers-after html "data-placement=\""))) ("report" . ,reports)
       ("version" . ,(car (numbers-after html "data-version=\"")))
       ("top" . ,(mark top)) ("spacer" . ,spacer?) ("fraction" . ,(/ offset 20))
       ("left" . ,(mark top)) ("past" . 0) ("sides" . #())
       ("start" . ,(append (mark whole-from) '(("count" . 0))))
       ("end" . ,(append (mark (max whole-from whole-to)) '(("count" . 0))))
       ("atStart" . ,(and (search html "data-run-at-start" 0) (= top 1) (= offset 0) #t))
       ("atEnd" . ,(and (search html "data-run-at-end" 0) (not (search html "data-spacer=\"below\"" 0))
                        (>= (+ top (quotient (+ h offset) 20)) (car (car (reverse marks)))) #t))
       ("columns" . 80) ("rows" . ,(quotient h 20)) ("pointVisible" . #t) ("lost" . #f)
       ("wanted" . ,(let* ([screens (string->number (let ([i (search html "data-drawn-screens=\"" 0)])
                                                       (substring html (+ i 20) (search html "\"" (+ i 20)))))]
                           [lines (+ (exact (ceiling (/ (* screens h) 20))) 1)])
                      `(("aboveLines" . ,lines) ("aboveChars" . ,(* lines 80)) ("belowLines" . ,lines) ("belowChars" . ,(* lines 80))
                        ("side" . ,(exact (ceiling (* screens 80)))))))
       ("settled" . ,settled?) ("hand" . #t) ("edge" . "top"))))
    (void)))

(define (line-of view p) (document:line (buffers:document (views:buffer view)) p))
(define (line-start view n) (document:line-start (buffers:document (views:buffer view)) n))
(define (lines n)
  (let loop ([i n] [acc '()])
    (if (= i 0) (apply string-append acc) (loop (- i 1) (cons (format "line ~a\n" i) acc)))))

(define (as-client client thunk)
  (parameterize ([web:current-client client]) (thunk)))
(import (console))
