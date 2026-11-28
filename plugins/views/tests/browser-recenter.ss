(import (tuna) (test) (test-browser) (cdp page) (views) (layout) (buffers) (document) (options) (tables) (editing) (echo-area)
        (status-line) (minibuffer))

(define page (test-browser:open (page-options [width 1200] [height 900] [color-scheme (color-scheme light)])))

(define b (buffers:make (buffers:free-name "long") (apply string-append (map (lambda (i) (format "line ~a\n" (+ i 1))) (iota 300)))))

(layout:switch-to-buffer b)

(define v (layout:selected-view))

(define (px text) (string->number (substring text 0 (- (string-length text) 2))))

(define (rows-around-point)
  (test-browser:call
    (lambda ()
      (let* ([view (car (page-query page (format "#view-~a" (views:id v))))]
             [cursor (car (page-query page (format "#view-~a .primary" (views:id v))))]
             [line (px (element-style view "--views-line-height"))]
             [box (element-box view)]
             [top (+ (rectangle-y box) (px (element-style view "padding-top")))]
             [bottom (- (+ (rectangle-y box) (rectangle-height box)) (px (element-style view "padding-bottom")))]
             [c (element-box cursor)])
        (list (exact (round (/ (- (rectangle-y c) top) line)))
              (exact (round (/ (- bottom (+ (rectangle-y c) (rectangle-height c))) line))))))))

(views:set-point! v (document:line-start (buffers:document b) 150))
(test-browser:wait-for-applied page)

(test "with a number C-l puts point on that row from the top, or from the bottom when negative, as the page lays the view out"
  (test-browser:press! page "C-u 2 C-l")
  (check-equal? 2 (car (rows-around-point)))
  (test-browser:press! page "C-u - 2 C-l")
  (check-equal? 1 (cadr (rows-around-point)))
  (test-browser:press! page "C-u 0 C-l")
  (check-equal? 0 (car (rows-around-point))))

(test "a row asked for inside the scroll margin is the first row outside it"
  (options:set! views:scroll-margin 3)
  (test-browser:press! page "C-u 1 C-l")
  (check-equal? 3 (car (rows-around-point)))
  (test-browser:press! page "M-- C-l")
  (check-equal? 3 (cadr (rows-around-point))))

(test "C-l's cycle keeps point's place outside the scroll margin at the top and the bottom, as a number does"
  (test-browser:press! page "C-g C-l C-l")
  (check-equal? 3 (car (rows-around-point)))
  (test-browser:press! page "C-l")
  (check-equal? 3 (cadr (rows-around-point))))

(buffers:define-layer tall-rows)

(tables:set! views:span-properties 'tall (lambda (v) '(("style" . "font-size: 250%"))))

(test "C-u N C-l counts the rows M-r counts, where a row is taller than the others"
  (let ([doc (buffers:document b)])
    (buffers:set-spans! (buffers:layer b tall-rows) 0 (document:length doc)
      (map (lambda (line) (list (document:line-start doc line) (- (document:line-start doc (+ line 1)) 1) '((tall . #t)))) '(143 155)))
    (test-browser:press! page "C-u 1 2 C-l")
    (let ([p (views:point v)])
      (test-browser:press! page "C-u 1 2 M-r")
      (check-equal? p (views:point v))
      (test-browser:press! page "C-u - 4 C-l")
      (test-browser:press! page "C-u - 4 M-r")
      (check-equal? p (views:point v)))))
