(import (tuna) (tuna plugins) (document) (haml) (web))
(use-plugin layout)
(use-plugin editing)
(use-plugin echo-area)
(use-plugin minibuffer)
(use-plugin completion)
(use-plugin jump-history)
(use-plugin isearch)
(use-plugin line-picker)
(use-plugin xref)

(define client (web:add-client! 1))

(define (view) (layout:selected-view))

(define (press! . keys)
  (for-each
    (lambda (key)
      (parameterize ([web:current-client client])
        (views:call-with-view (view) (lambda () (keys:press! client key)))))
    keys))

;; A key whose command reads pauses its task, so it is pressed in a task
;; of its own.
(define (start! . keys)
  (spawn-task (lambda () (apply press! keys)))
  (sleep-for 0.05))

(define (type! text) (apply press! (map (lambda (c) (if (char=? c #\space) "SPC" (string c))) (string->list text))))

(define (numbered-lines n)
  (let loop ([i n] [acc '()])
    (if (= i 0)
        (apply string-append acc)
        (loop (- i 1) (cons (format "line ~a~a\n" (make-string (- 3 (string-length (number->string i))) #\0) i) acc)))))

(define (doc) (buffers:document (views:buffer (view))))
(define (line-start n) (max 1 (document:line-start (doc) n)))
(define (point-at)
  (let* ([p (views:point (view))] [line (document:line (doc) p)])
    (list line (- p (line-start line)))))

(define (number-after html key)
  (let ([n (string-length key)])
    (let loop ([i 0])
      (cond
        [(> (+ i n) (string-length html)) #f]
        [(string=? (substring html i (+ i n)) key)
         (let digits ([j (+ i n)] [k 0])
           (if (and (< j (string-length html)) (char-numeric? (string-ref html j)))
               (digits (+ j 1) (+ (* k 10) (- (char->integer (string-ref html j)) 48)))
               k))]
        [else (loop (+ i 1))]))))

(define (word-after html key)
  (let ([n (string-length key)])
    (let loop ([i 0])
      (cond
        [(> (+ i n) (string-length html)) #f]
        [(string=? (substring html i (+ i n)) key)
         (let end ([j (+ i n)])
           (if (char=? (string-ref html j) #\") (string->symbol (substring html (+ i n) j)) (end (+ j 1))))]
        [else (loop (+ i 1))]))))

(define (html) (html->string (views:draw (view) client)))

;; The placement the page is sent: its kind and, for a place, its line.
(define (placement)
  (let* ([h (html)] [kind (word-after h "data-place-kind=\"")] [at (number-after h "data-place-at=\"")])
    (if (memq kind '(top center bottom)) (list kind (document:line (doc) at)) (list kind))))

;; Stands for a page 21 rows high showing the view from line TOP, each
;; line one row: it reports what it shows, at rest.
(define rows 21)
(define reports 0)
(define (page-report top)
  (set! reports (+ reports 1))
  (let ([h (html)] [mark (lambda (line) (list (cons "line" line)))])
    `(("type" . "scroll") ("view" . ,(views:id (view))) ("placement" . ,(number-after h "data-placement=\""))
      ("report" . ,reports) ("version" . ,(number-after h "data-version=\"")) ("slotVersion" . ,(number-after h "data-slot-version=\""))
      ("top" . ,(mark top)) ("spacer" . #f) ("fraction" . 0) ("left" . null) ("past" . 0) ("sides" . #())
      ("start" . ,(mark top)) ("end" . ,(mark (+ top rows -1))) ("atStart" . ,(= top 1)) ("atEnd" . #f)
      ("columns" . 80) ("rows" . ,rows) ("pointVisible" . #t) ("lost" . #f) ("wanted" . null)
      ("hand" . #f) ("settled" . #f) ("edge" . "top"))))

(define (show-at! top)
  (parameterize ([web:current-client client])
    ((table-ref web:input-handlers "scroll") client (page-report top))))

;; The page's answers to the commands that need its geometry: C-v and
;; M-v step by the view's height less the context lines, or by the
;; prefix, and stop at the end, where the end is at the bottom edge; M-r
;; names the start of a row. Each request is kept.
(define page-top 1)
(define requests '())
(define last-line 201)
(define (answer ask c name value)
  (let ([field (lambda (k) (cdr (assoc k value)))])
    (cond
      [(and (equal? name "views-page") (field "sideways"))
       (set! requests (cons (list 'sideways (field "forward") (field "context") (field "by")) requests))
       `(("report" . ,(page-report page-top)))]
      [(equal? name "views-page")
       (set! requests (cons (list (field "forward") (field "by")) requests))
       (let* ([step (if (eq? (field "by") 'null) (- rows (field "context")) (field "by"))]
              [most (- last-line rows -1)]
              [top (max 1 (min most (if (field "forward") (+ page-top step) (- page-top step))))])
         (if (= top page-top)
             '(("limit" . #t))
             (begin
               (set! page-top top)
               (let ([r (page-report top)])
                 `(("report" . ,(map (lambda (e) (cond [(equal? (car e) "hand") '("hand" . #t)] [(equal? (car e) "settled") '("settled" . #t)] [else e])) r)))))))]
      [(equal? name "views-row")
       (set! requests (cons (list (field "row")) requests))
       (let ([row (field "row")])
         `(("version" . ,(buffers:version (views:buffer (view))))
           ("at" . (("line" . ,(+ page-top (cond [(eq? row 'null) (quotient rows 2)] [(< row 0) (+ rows row)] [else row])))))))]
      [else (ask c name value)])))
(advice-add! web:ask-page answer)

(define (requested) (let ([r (reverse requests)]) (set! requests '()) r))

(define (start-at! top line)
  (views:set-point! (view) (line-start line))
  (views:scroll-to! (view) (line-start top) (views:align top))
  (set! page-top top)
  (show-at! top))

;; Ten short lines, a line of 300 characters, ten more short lines, in a
;; view whose lines do not wrap.
(define (show-long-line!)
  (layout:switch-to-buffer
    (buffers:make "*long*"
      (string-append (numbered-lines 10) (make-string 300 #\a) "\n"
                     (apply string-append (map (lambda (i) (format "after 0~a\n" i)) (iota 10))))))
  (views:set-option! (view) views:wrap-lines #f)
  (set! last-line 22))

(define (show-lines! n)
  (layout:switch-to-buffer (buffers:make "*lines*" (numbered-lines n)))
  (set! last-line (+ n 1)))

;; A file whose second line calls what line 150 defines, and a backend
;; that finds the definition.
(define target-path (string-append (getenv "HOME") "/target.el"))
(with-output-to-file target-path
  (lambda ()
    (display ";;; target.el\n(defun scrolling-caller () (scrolling-target-function))\n")
    (do ([i 3 (+ i 1)]) ((= i 150)) (printf ";; filler ~a\n" i))
    (display "(defun scrolling-target-function ()\n  \"Target.\"\n  42)\n")
    (do ([i 153 (+ i 1)]) ((= i 200)) (printf ";; filler ~a\n" i))))
(add-hook! xref:backends
  (lambda (v)
    (xref:backend "target"
      [identifier-at-point (lambda (v) "scrolling-target-function")]
      [definitions (lambda (name) (list (xref:make-item name target-path 150 0)))])))
(import (console))
