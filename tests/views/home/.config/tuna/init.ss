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

(define (drawn view client)
  (let* ([html (html-of view client)] [ls (numbers-after html "data-line=\"")])
    (list (car ls) (car (reverse ls)) (length ls)
          (numbers-after html "--views-spacer-block-size:") (numbers-after html "--views-scroll-sizer-block-size:"))))

(define seen '())

(define (placement view client)
  (let* ([html (html-of view client)] [n (car (numbers-after html "data-placement=\""))]
         [key (cons (views:id view) (web:client-number client))] [last (assoc key seen)])
    (set! seen (cons (cons key n) seen))
    (list (if (and last (= (cdr last) n)) 'same 'new) (car (numbers-after html "data-place-line=\""))
          (word-after html "data-place-align=\""))))

(define reports 0)

(define (report! client view top offset settled? . overrides)
  (let* ([html (html-of view client)]
         [ls (numbers-after html "data-line=\"")]
         [first (car ls)] [last (car (reverse ls))]
         [h (height-of client)]
         [at (lambda (line) (- (* 20 (- line top)) offset))]
         [spacer (cond [(< top first) "above"] [(> top last) "below"] [else 'null])]
         [named (cond [(< top first) first] [(> top last) last] [else top])]
         [whole (let loop ([k named]) (if (and (<= k last) (<= (+ (at k) 20) (+ h 0.5))) (loop (+ k 1)) (- k 1)))])
    (set! reports (+ reports 1))
    ((table-ref web:input-handlers "scroll") client
     (map (lambda (field) (or (assoc (car field) overrides) field))
     `(("type" . "scroll") ("view" . ,(views:id view))
       ("placement" . ,(car (numbers-after html "data-placement=\""))) ("report" . ,reports)
       ("top" . ,named) ("offset" . ,(if (eq? spacer 'null) offset 0))
       ("lastVisible" . ,(if (and (string? spacer) (or (< whole first) (< (at whole) -0.5))) 'null (max whole named)))
       ("spacer" . ,spacer)
       ("spacerDistance" . ,(cond [(equal? spacer "above") (at first)] [(equal? spacer "below") (- (+ (at last) 20))] [else 0]))
       ("before" . ,(- named first)) ("after" . ,(- last named))
       ("drawnHeight" . ,(* 20 (+ 1 (- last first))))
       ("above" . ,(max 0 (- (at first)))) ("below" . ,(max 0 (- (+ (at last) 20) h)))
       ("width" . 800) ("height" . ,h) ("settled" . ,settled?))))
    (void)))

(define (line-of view p) (document:line (buffers:document (views:buffer view)) p))
(define (line-start view n) (document:line-start (buffers:document (views:buffer view)) n))
(define (lines n)
  (let loop ([i n] [acc '()])
    (if (= i 0) (apply string-append acc) (loop (- i 1) (cons (format "line ~a\n" i) acc)))))

(define (as-client client thunk)
  (parameterize ([web:current-client client]) (thunk)))
(import (console))
