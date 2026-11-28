(import (tuna) (test) (test-runner) (test-browser) (cdp page) (design-tokens) (layout) (layout-split) (layout-scroll) (views)
        (buffers) (document))

(define page (test-browser:open (page-options [width 1200] [height 800] [color-scheme (color-scheme light)])))

(define (fresh name) (views:make (or (buffers:find name) (buffers:make name (string-append name "\n")))))

(define (atom view . attributes)
  (views:view (cons* (cons 'view (views:id view)) (cons 'buffer (buffers:name (views:buffer view))) attributes)))

(define (show! . columns)
  (let ([n (document:length (buffers:document layout:buffer))])
    (buffers:replace! layout:buffer 1 (- n 1) (document:from-datum (apply layout-scroll:container '() columns))))
  (layout:select! (car (layout:views)))
  (test-browser:wait-for-applied page))

(define (attributes-of v)
  (remp (lambda (a) (memq (car a) '(view buffer)))
        (let find-in ([d (car (document:datums (buffers:document layout:buffer)))])
          (if (vector? d)
              (and (eqv? (views:id v) (cdr (assq 'view (vector-ref d 1)))) (vector-ref d 1))
              (exists find-in (cddr d))))))

(define (query selector) (test-browser:call (lambda () (page-query page selector))))

(define (box e) (test-browser:call (lambda () (element-box e))))

(define (style e property) (test-browser:call (lambda () (element-style e property))))

(define (start-of v) (document:node-start (layout:view-node v)))

(define (handle-of v) (car (query (format ".strip-handle[data-at=\"~a\"]" (start-of v)))))

(define (column-of v) (car (query (format ".strip-item:has(> [data-at=\"~a\"]:not(.strip-handle))" (start-of v)))))

(define (rule-of v) (if (string=? "0px" (style (column-of v) "border-left-width")) 0 1))

(define (length-of v) (- (rectangle-width (box (column-of v))) (rule-of v)))

(define (left-of v) (rectangle-x (box (column-of v))))

(define (cell v)
  (let ([s (style (column-of v) "--layout-cell-width")]) (string->number (substring s 0 (- (string-length s) 2)))))

(define (centre e)
  (let ([r (box e)]) (make-point (+ (rectangle-x r) (/ (rectangle-width r) 2)) (+ (rectangle-y r) (/ (rectangle-height r) 2)))))

(define (near? a b) (< (abs (- a b)) 1))

;; The page follows a press once Tuna's question about it arrives, which a
;; press that changes no screen sends after the press's answer.
(define (held-drag! v dx)
  (let ([at (centre (handle-of v))] [was (length-of v)])
    (test-browser:press-button! page (handle-of v))
    (test-browser:move-pointer! page (make-point (+ (point-x at) (/ dx 2)) (point-y at)))
    (test-browser:move-pointer! page (make-point (+ (point-x at) dx) (point-y at)))
    (test-runner:wait-until (lambda () (not (near? was (length-of v)))))))

(test "a handle shows the resize pointer and lights under it, and a column that fits its content has none"
  (let ([a (fresh "a")] [b (fresh "b")])
    (show! (atom a '(size . 1/3)) (atom b '(size . content)))
    (check-equal? "col-resize" (style (handle-of a) "cursor"))
    (check-equal? "rgba(0, 0, 0, 0)" (style (handle-of a) "background-color"))
    (let ([handle (handle-of a)]) (test-browser:call (lambda () (element-hover! handle))))
    (check (not (equal? "rgba(0, 0, 0, 0)" (style (handle-of a) "background-color"))))
    (check-equal? '() (query (format ".strip-handle[data-at=\"~a\"]" (start-of b))))))

;; A third of the scrollport is the first column's length, so the length
;; shown over the scrollport is the size stored.
(test "a column follows the pointer, the strip neither scrolls nor moves its focus, and the size stored is the length shown over the scrollport"
  (let ([a (fresh "a")] [b (fresh "b")] [c (fresh "c")])
    (show! (atom a '(size . 1/3)) (atom b '(size . 1/2)) (atom c '(size . 1/3)))
    (let ([before (length-of a)] [left (left-of a)] [c-left (left-of c)])
      (held-drag! a 100)
      (check-compare near? (+ before 100) (length-of a))
      (check-compare near? (+ c-left 100) (left-of c))
      (test-browser:release-button! page)
      (check-compare near? (+ before 100) (length-of a))
      (check-compare near? left (left-of a))
      (check (eq? a (layout:selected-view)))
      (check-compare (lambda (x y) (< (abs (- x y)) 1/1000))
                     (/ (+ before 100) (* 3 before))
                     (cdr (assq 'size (attributes-of a)))))))

(test "a column sized in columns moves by whole columns, and stops at its minimum"
  (let ([a (fresh "a")] [b (fresh "b")])
    (show! (atom a '(size columns 40)) (atom b '(size . 1/2)))
    (let ([one (cell a)])
      (held-drag! a (* 4.4 one))
      (check-compare near? (* 44 one) (length-of a))
      (test-browser:release-button! page)
      (check-equal? '((size columns 44)) (attributes-of a))
      (held-drag! a -2000)
      (check-compare near? (* 10 one) (length-of a))
      (test-browser:release-button! page)
      (check-equal? '((size columns 10)) (attributes-of a)))))

(test "a double click on a handle gives the column the default size"
  (let ([a (fresh "a")] [b (fresh "b")])
    (show! (atom a '(size . 1/3)) (atom b '(size . 1/3)))
    (test-browser:double-click! page (handle-of a))
    (check-equal? '((size . 1/2)) (attributes-of a))))

;; Snapping, off while the button is down, comes back on at the release
;; and may carry the strip to a snap position a pixel or two away.
(test "a column before the focused one, in a strip scrolled along, changes length without the strip scrolling or the focus moving"
  (let ([a (fresh "a")] [b (fresh "b")] [c (fresh "c")] [d (fresh "d")])
    (show! (atom a '(size . 1/2)) (atom b '(size . 1/2)) (atom c '(size . 1/2)) (atom d '(size . 1/2)))
    (layout:select! c)
    (test-browser:wait-for-applied page)
    (test-runner:wait-until (lambda () (< (left-of a) 0)))
    (let ([offset (left-of a)] [left (left-of c)] [before (length-of b)])
      (held-drag! b -100)
      (check-compare near? (- left 100) (left-of c))
      (test-browser:release-button! page)
      (check-compare near? (- before 100) (length-of b))
      (check-compare (lambda (x y) (< (abs (- x y)) 3)) offset (left-of a))
      (check-compare (lambda (x y) (< (abs (- x y)) 3)) (- left 100) (left-of c))
      (check (eq? c (layout:selected-view))))))
