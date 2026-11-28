(import (tuna) (test) (test-runner) (test-browser) (cdp page) (design-tokens) (layout) (layout-split) (views) (buffers)
        (document) (layout-split-test parts))

(define atom layout-split-test/parts:atom)
(define named layout-split-test/parts:named)
(define set-parts! layout-split-test/parts:set-parts!)
(define attributes-of layout-split-test/parts:attributes-of)

;; As a user's init.ss overrides it: a drag goes on into the next part
;; when the nearest is at its minimum, as Emacs's does.
(define (layout-split:drag-chain split parts)
  (let loop ([cs parts] [chain '()])
    (if (or (null? cs) (layout:locked? (car cs)) (eq? (document:node-attribute (car cs) 'size #f) 'content))
        (reverse chain)
        (loop (cdr cs) (cons (car cs) chain)))))

(define page (test-browser:open (page-options [width 1200] [height 800] [color-scheme (color-scheme light)])))

(define (fresh name) (views:make (named name)))

(define (query selector) (test-browser:call (lambda () (page-query page selector))))

(define (box e) (test-browser:call (lambda () (element-box e))))

(define (style e property) (test-browser:call (lambda () (element-style e property))))

(define (start-of v) (document:node-start (layout:view-node v)))

(define (divider-before v) (car (query (format ".split-divider[data-at=\"~a\"]" (start-of v)))))

(define (part-element v) (car (query (format ".split-child:has(> :not(.split-divider)[data-at=\"~a\"])" (start-of v)))))

(define (rule-of v) (if (string=? "0px" (style (part-element v) "border-left-width")) 0 1))

(define (length-of v) (- (rectangle-width (box (part-element v))) (rule-of v)))

(define (cell v)
  (let ([s (style (part-element v) "--layout-cell-width")]) (string->number (substring s 0 (- (string-length s) 2)))))

(define (centre e)
  (let ([r (box e)]) (make-point (+ (rectangle-x r) (/ (rectangle-width r) 2)) (+ (rectangle-y r) (/ (rectangle-height r) 2)))))

(define (near? a b) (< (abs (- a b)) 1))

(define (columns-of v) (let ([s (assq 'size (attributes-of v))]) (and s (caddr s))))

(test "a drag past a weighted part's minimum goes on into a part sized in columns, every counted part moves by whole columns, and the edge keeps up with the pointer"
  (let ([a (fresh "a")] [b (fresh "b")] [c (fresh "c")])
    (set-parts! (layout-split:container '((direction . row)) (atom a '(size columns 20)) (atom b) (atom c '(size columns 60))))
    (layout:select! a)
    (test-browser:wait-for-applied page)
    (let* ([one (cell a)] [at (centre (divider-before b))] [b-room (- (length-of b) (* 10 one))])
      (test-browser:press-button! page (divider-before b))
      (test-browser:move-pointer! page (make-point (+ (point-x at) (+ b-room (* 15.3 one))) (point-y at)))
      (test-runner:wait-until (lambda () (> (length-of a) (* 21 one))))
      (let ([shown (map length-of (list a b c))])
        (check (< (abs (- (/ (car shown) one) (round (/ (car shown) one)))) 1/100))
        (check (< (abs (- (/ (caddr shown) one) (round (/ (caddr shown) one)))) 1/100))
        (check (< (cadr shown) (* 11 one)))
        (check (< (caddr shown) (* 59 one)))
        (check-equal? (+ 20 (exact (round (/ (+ b-room (* 15.3 one)) one)))) (exact (round (/ (car shown) one))))
        (test-browser:release-button! page)
        (check-equal? (list (exact (round (/ (car shown) one))) (exact (round (/ (caddr shown) one)))) (map columns-of (list a c)))
        (for-each (lambda (x y) (check-compare near? x y)) shown (map length-of (list a b c)))))))
