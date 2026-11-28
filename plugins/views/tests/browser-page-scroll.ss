(import (tuna) (test) (test-runner) (test-browser) (cdp page) (views) (layout) (buffers) (document) (options) (commands)
        (editing) (echo-area) (status-line) (minibuffer))

(define page (test-browser:open (page-options [width 1200] [height 900] [color-scheme (color-scheme light)])))

(define b (buffers:make (buffers:free-name "long") (apply string-append (map (lambda (i) (format "line ~a\n" (+ i 1))) (iota 300)))))

(layout:switch-to-buffer b)

(define v (layout:selected-view))

(define (px text) (string->number (substring text 0 (- (string-length text) 2))))

(define (view-element) (car (page-query page (format "#view-~a" (views:id v)))))

(define (cursor-box) (element-box (car (page-query page (format "#view-~a .cursor.primary, #view-~a .cursor-on.primary" (views:id v) (views:id v))))))

(define (row-of-point)
  (test-browser:call
    (lambda ()
      (let* ([view (view-element)]
             [top (+ (rectangle-y (element-box view)) (px (element-style view "padding-top")))])
        (exact (round (/ (- (rectangle-y (cursor-box)) top) (px (element-style view "--views-line-height")))))))))

;; A scroll command asks the page and waits for its answer, which the
;; key's request does not.
(define (scroll! keys command)
  (test-browser:press! page keys)
  (test-runner:wait-until (lambda () (eq? command (commands:last-command))))
  (test-browser:wait-for-applied page))

(define (column-start line) (+ (document:line-start (buffers:document b) line) 3))

(test "with views:page-scroll-keeps-row off, point that C-v leaves above the view goes to the first row"
  (views:set-point! v (column-start 10))
  (test-browser:wait-for-applied page)
  (scroll! "C-v" views:scroll-up)
  (check-equal? 0 (row-of-point))
  (test-browser:press! page "M-<")
  (test-browser:wait-for-applied page))

(test "with views:page-scroll-keeps-row on, C-v keeps point on its row and column, and M-v after it brings point back"
  (options:set! views:page-scroll-keeps-row #t)
  (views:set-point! v (column-start 10))
  (test-browser:wait-for-applied page)
  (let ([row (row-of-point)] [p (views:point v)])
    (scroll! "C-v" views:scroll-up)
    (check-equal? row (row-of-point))
    (check (> (views:point v) p))
    (check-equal? 3 (- (views:point v) (document:line-start (buffers:document b) (document:line (buffers:document b) (views:point v)))))
    (scroll! "M-v" views:scroll-down)
    (check-equal? p (views:point v)))
  (options:set! views:page-scroll-keeps-row #f))

(define wide (buffers:make (buffers:free-name "wide") (string-append (make-string 400 #\x) "\n")))

(test "where lines do not wrap, point followed sideways keeps views:sideways-margin columns from the right edge, and from the left edge once the view has scrolled"
  (buffers:with-buffer wide (options:set-local! views:wrap-lines #f))
  (layout:switch-to-buffer wide)
  (for-each
    (lambda (margin)
      (options:set! views:sideways-margin margin)
      (views:set-point! v 0)
      (test-browser:wait-for-applied page)
      (views:set-point! v 200)
      (test-browser:wait-for-applied page)
      (let ([at-200 (test-browser:call cursor-box)])
        (views:set-point! v 195)
        (test-browser:wait-for-applied page)
        (let* ([column (/ (- (rectangle-x at-200) (rectangle-x (test-browser:call cursor-box))) 5)]
               [right (test-browser:call
                        (lambda ()
                          (let* ([view (view-element)] [box (element-box view)])
                            (- (+ (rectangle-x box) (rectangle-width box)) (px (element-style view "padding-right"))))))]
               [gap (- right (+ (rectangle-x at-200) (rectangle-width at-200)))])
          (check (< (abs (- gap (* margin column))) 2))
          (views:set-point! v 30)
          (test-browser:wait-for-applied page)
          (let ([left (test-browser:call
                        (lambda ()
                          (let ([view (view-element)])
                            (+ (rectangle-x (element-box view)) (px (element-style view "padding-left"))))))])
            (check (< (abs (- (- (rectangle-x (test-browser:call cursor-box)) left) (* margin column))) 2))))))
    '(0 5 12))
  (check-raises message-condition? (options:set! views:sideways-margin -1)))
