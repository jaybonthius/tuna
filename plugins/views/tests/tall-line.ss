(import (tuna) (test) (views) (buffers) (options) (layout) (editing) (web) (test-user)
        (views-test page) (views-test text) (views-test md))

(options:set! views:scroll-margin 2 views:wrap-lines #f)

(buffers:define-kind rows (content nodes))
(buffers:define-kind row (content atom))

(define (paras from n)
  (map (lambda (i) (views-test/md:para '() (format "line ~a\n" (+ from i)))) (iota n)))

(define b
  (buffers:make (buffers:free-name "tall")
    (apply views-test/md:doc '()
      (append (paras 1 100)
              (list (views-test/md:heading '() "Rows\n") (apply rows '() (map (lambda (i) (row '())) (iota 200)))
                    (views-test/md:para '() "after\n"))
              (paras 103 100)))))

(define v (layout:selected-view))
(views:set-buffer! v b)

(define desktop (views-test/page:open 400))
(define c (views-test/page:client desktop))
(define height 400)

(define (line-of p) (views-test/text:line-of v p))
(define (line-start n) (views-test/text:line-start v n))

;; The page lays out lines 20 px high and atoms 30, each spacer a line per
;; row. Every redraw keeps the item at the top edge still, then the page
;; carries out a new placement; a place in a spacer is the line its counts
;; put there.
(define-record-type item-box (fields mark to top height index))

(define (item-box-bottom b) (+ (item-box-top b) (item-box-height b)))

(define (attribute e name) (test-user:element-attribute e name))

(define (number e name) (let ([s (attribute e name)]) (and s (string->number s))))

(define (classed e) (test-user:elements-with e "class"))

(define (line-item? x) (equal? "line" (attribute x "class")))

(define (whole-item? x)
  (let ([class (attribute x "class")])
    (and (>= (string-length class) 10) (string=? "node whole" (substring class 0 10)))))

(define (spacer-field e side name)
  (let ([s (find (lambda (s) (equal? side (attribute s "data-spacer"))) (test-user:elements e "view-spacer"))])
    (and s (number s name))))

(define (lay-out e)
  (let loop ([xs (classed e)] [i 0] [y (* 20 (or (spacer-field e "above" "data-lines") 0))] [acc '()])
    (cond
      [(null? xs) (values (reverse acc) (+ y (* 20 (or (spacer-field e "below" "data-lines") 0))))]
      [(or (line-item? (car xs)) (whole-item? (car xs)))
       (let* ([x (car xs)]
              [mark (if (number x "data-at") (list (cons "at" (number x "data-at"))) (list (cons "line" (number x "data-line"))))]
              [to (and (whole-item? x) (number x "data-to"))]
              [px (if to 30 20)])
         (loop (cdr xs) (+ i 1) (+ y px) (cons (make-item-box mark to y px i) acc)))]
      [else (loop (cdr xs) (+ i 1) y acc)])))

(define scroll-top 0)
(define shown-placement #f)
(define shown-boxes '())

(define (margin-of h) (min 40 (/ h 4)))

(define (box-of boxes mark) (find (lambda (b) (equal? (item-box-mark b) mark)) boxes))

(define (index-of e found?)
  (let loop ([xs (classed e)] [i 0])
    (cond [(null? xs) #f] [(found? (car xs)) i] [else (loop (cdr xs) (+ i 1))])))

(define (class-is name) (lambda (x) (equal? name (attribute x "class"))))

(define (item-holding e boxes found?)
  (let ([i (index-of e found?)])
    (and i (let ([before (filter (lambda (b) (<= (item-box-index b) i)) boxes)])
             (and (pair? before) (car (last-pair before)))))))

(define (item-after e boxes found?)
  (let ([i (index-of e found?)])
    (and i (find (lambda (b) (> (item-box-index b) i)) boxes))))

(define (point-box e boxes)
  (or (item-holding e boxes (class-is "cursor-on primary"))
      (item-holding e boxes (class-is "node whole at-cursor primary"))
      (item-after e boxes (class-is "cursor primary"))))

(define (centered b h) (- (+ (item-box-top b) (/ (item-box-height b) 2)) (/ h 2)))

(define (position! e boxes)
  (let ([b (box-of boxes (let ([line (number e "data-place-line")])
                           (if line (list (cons "line" line)) (list (cons "at" (number e "data-place-item"))))))])
    (when b
      (set! scroll-top (+ (item-box-top b) (* (or (number e "data-place-fraction") 0) (item-box-height b)))))))

(define (follow! e boxes h)
  (let ([b (point-box e boxes)] [margin (margin-of h)] [top scroll-top])
    (when b
      (let ([bottom (item-box-bottom b)])
        (unless (if (> (item-box-height b) (- h (* 2 margin)))
                    (and (> bottom top) (< (item-box-top b) (+ top h)))
                    (and (>= (item-box-top b) (+ top margin -1/2)) (<= bottom (+ top h (- margin) 1/2))))
          (set! scroll-top
            (if (< (item-box-top b) (+ top margin))
                (if (<= (- (+ top margin) (item-box-top b)) h) (- (item-box-top b) margin) (centered b h))
                (if (<= (- bottom (+ top h (- margin))) h) (+ (- bottom h) margin) (centered b h)))))))))

(define (box-start b)
  (let ([m (car (item-box-mark b))]) (if (equal? (car m) "at") (cdr m) (line-start (cdr m)))))

(define (place! e boxes h)
  (let ([b (or (item-holding e boxes (class-is "view-place"))
               (let ([at (number e "data-place-at")])
                 (and at (find (lambda (b) (>= (box-start b) at)) boxes))))])
    (case (string->symbol (attribute e "data-place-kind"))
      [(position) (position! e boxes)]
      [(follow) (unless shown-placement (position! e boxes)) (follow! e boxes h)]
      [(top) (when b (set! scroll-top (item-box-top b)))]
      [(center) (when b (set! scroll-top (centered b h)))]
      [(bottom) (when b (set! scroll-top (- (item-box-bottom b) h)))])))

(define (anchor! boxes)
  (let* ([old (find (lambda (b) (> (item-box-bottom b) scroll-top)) shown-boxes)]
         [new (and old (<= (item-box-top old) scroll-top) (box-of boxes (item-box-mark old)))])
    (when new (set! scroll-top (+ scroll-top (- (item-box-top new) (item-box-top old)))))))

(define (show!)
  (let ([e (views-test/page:view-element desktop v)])
    (let-values ([(boxes total) (lay-out e)])
      (define (clamp!) (set! scroll-top (max 0 (min scroll-top (- total height)))))
      (anchor! boxes)
      (clamp!)
      (let ([placement (number e "data-placement")])
        (unless (eqv? placement shown-placement)
          (place! e boxes height)
          (clamp!))
        (set! shown-placement placement))
      (set! shown-boxes boxes)
      e)))

(define (place-at e boxes y)
  (let ([first (car boxes)] [last (car (last-pair boxes))])
    (cond
      [(and (< y (item-box-top first)) (spacer-field e "above" "data-line"))
       => (lambda (line) (values (list (cons "line" (+ line (exact (floor (/ y 20)))))) (/ (mod y 20) 20) #t #f))]
      [(and (>= y (item-box-bottom last)) (spacer-field e "below" "data-line"))
       => (lambda (line)
            (let ([d (- y (item-box-bottom last))])
              (values (list (cons "line" (+ line (exact (floor (/ d 20)))))) (/ (mod d 20) 20) #t #f)))]
      [else (let ([b (find (lambda (b) (> (item-box-bottom b) y)) boxes)])
              (values (item-box-mark b) (/ (- y (item-box-top b)) (item-box-height b)) #f b))])))

(define (measure e hand?)
  (let* ([h height] [boxes shown-boxes] [margin (margin-of h)] [room (- h (* 2 margin))]
         [row (lambda (y down?)
                (let-values ([(mark fraction spacer? b) (place-at e boxes y)])
                  (cond
                    [(and b (item-box-to b) (> (item-box-height b) room)) (item-box-mark b)]
                    [(> fraction 1/40)
                     (let-values ([(next f s n) (place-at e boxes (if down?
                                                                      (+ y (* (- 1 fraction) (if b (item-box-height b) 20)) 1/2)
                                                                      (- y (* fraction (if b (item-box-height b) 20)) 1/2)))])
                       next)]
                    [else mark])))]
         [p (point-box e boxes)])
    (let-values ([(top fraction spacer? b) (place-at e boxes scroll-top)])
      `(("type" . "scroll") ("view" . ,(views:id v)) ("placement" . ,(number e "data-placement"))
        ("version" . ,(number e "data-version"))
        ("top" . ,top) ("spacer" . ,spacer?) ("fraction" . ,(inexact fraction)) ("left" . null) ("past" . 0) ("sides" . #())
        ("start" . ,(row (+ scroll-top margin) #t)) ("end" . ,(row (- (+ scroll-top h) margin 1) #f))
        ("atStart" . ,(<= scroll-top 0)) ("atEnd" . #f) ("columns" . 80) ("rows" . ,(quotient h 20))
        ("pointVisible" . ,(and p (>= (item-box-top p) scroll-top) (<= (item-box-bottom p) (+ scroll-top h)) #t))
        ("wanted" . (("aboveLines" . 41) ("aboveChars" . 3280) ("belowLines" . 41) ("belowChars" . 3280) ("side" . 160)))
        ("hand" . ,hand?) ("edge" . "top")))))

(define reports 0)

(define (send! r settled?)
  (set! reports (+ reports 1))
  (web:post-input! c (append r `(("report" . ,reports) ("settled" . ,settled?))))
  (test-user:settle))

(define (settle-reports! hand?)
  (let loop ([k 0] [last #f])
    (let ([r (measure (show!) hand?)])
      (cond
        [(equal? r last) (send! r #t) (show!) (void)]
        [(= k 50) (error 'settle-reports! "the reports never settle")]
        [else (send! r #f) (loop (+ k 1) r)]))))

(define (scroll-by-hand! px) (set! scroll-top px) (settle-reports! #t))

(define (point-shown?)
  (let ([b (point-box (views-test/page:view-element desktop v) shown-boxes)])
    (and b (<= scroll-top (item-box-top b)) (<= (item-box-bottom b) (+ scroll-top height)))))

(test "a view placed at the heading above a line taller than the view shows the heading at its top"
  (settle-reports! #f)
  (views:set-point! v (line-start 101))
  (views:scroll-to! v (line-start 101) (views:align top))
  (settle-reports! #f)
  (check-equal? '(101 101) (list (line-of (views:point v)) (line-of (views:top v c)))))

(test "C-n from the heading puts point on the tall line, and the view follows it there and stays once the page's reports settle"
  (test-user:press! c "C-n")
  (check-equal? 102 (line-of (views:point v)))
  (settle-reports! #f)
  (check-equal? '(102 100 #t) (list (line-of (views:point v)) (line-of (views:top v c)) (point-shown?)))
  (settle-reports! #f)
  (check-equal? '(102 100 #t) (list (line-of (views:point v)) (line-of (views:top v c)) (point-shown?))))

(test "scrolled by hand into the spacer above the drawn run, the view stays where the hand left it, and point comes into view"
  (scroll-by-hand! 500)
  (check-equal? '(42 26 #t) (list (line-of (views:point v)) (line-of (views:top v c)) (point-shown?))))
