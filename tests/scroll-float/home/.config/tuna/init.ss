(import (tuna) (tuna plugins) (document) (haml) (web))
(use-plugin layout-split)
(use-plugin layout-scroll)
(use-plugin layout-float)
(use-plugin layout)

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))

(define (tree)
  (car (document:datums (buffers:document layout:buffer))))

(define (ids) (map views:id (layout:views)))

(define (selected) (views:id (layout:selected-view)))

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

(define (screen-of client) (html->string (layout:screen client)))

(define (atom view . attributes)
  (views:view (cons* (cons 'view (views:id view)) (cons 'buffer (buffers:name (views:buffer view))) attributes)))

(define (set-parts! . parts)
  (let ([n (document:length (buffers:document layout:buffer))])
    (buffers:replace! layout:buffer 1 (- n 1) (apply document:from-datum parts))
    (void)))

(define (press! client . keys)
  (for-each
    (lambda (key)
      ((table-ref web:input-handlers "key") client
       (list (cons "type" "key") (cons "key" (car key)) (cons "code" "") (cons "modifiers" (list->vector (cdr key))))))
    keys))
(define (lines name n)
  (let loop ([i n] [acc '()])
    (if (= i 0) (apply string-append acc) (loop (- i 1) (cons (format "~a ~a\n" name i) acc)))))

(define (strip client)
  (let ([html (screen-of client)])
    (list (car (numbers-after html "data-place-item=\"")) (word-after html "data-place-align=\"")
          (car (numbers-after html "data-place-focus=\""))
          (let loop ([from 0] [acc '()])
            (let ([i (search html "data-item=\"" from)])
              (if i
                  (let* ([id (car (numbers-after (substring html i (+ i 30)) "data-item=\""))]
                         [next (search html "data-item=\"" (+ i 1))]
                         [body (substring html i (or next (string-length html)))])
                    (loop (+ i 1) (cons (if (search body "strip-placeholder" 0) (list id 'placeholder) id) acc)))
                  (reverse acc)))))))

(define reports 0)

(define (strip-report! client items . rest)
  (let ([html (screen-of client)])
    (set! reports (+ reports 1))
    ((table-ref web:input-handlers "scroller") client
     (append `(("type" . "scroller") ("scroller" . ,(car (numbers-after html "data-scroller=\"")))
               ("placement" . ,(car (numbers-after html "data-placement=\""))) ("report" . ,reports)
               ("items" . ,(list->vector items)) ("settled" . ,(pair? rest)))
             (if (pair? rest) `(("item" . ,(car rest)) ("align" . ,(cadr rest)) ("focus" . ,(caddr rest))) '())))))

(define (placement-number client)
  (car (numbers-after (screen-of client) "data-placement=\"")))
(import (console))
