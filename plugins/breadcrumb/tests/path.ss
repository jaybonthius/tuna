(import (tuna) (test) (test-runner) (test-user) (options) (tables) (modes) (buffers) (document) (views) (layout) (layout-split) (editing)
        (jump-history) (status-line) (outline) (breadcrumb) (status-line-test) (outline-test toy))

(options:set! outline:idle-delay 0.05)

(define cart-text "notes\nclass Cart\n  method total\n    body\n  method add\n    body\nfunction helper\n  body\n")

(define cart (buffers:make "cart.toy" cart-text))
(modes:set-major-mode outline-test/toy:mode cart)

(define (view) (layout:selected-view))

(define (go! line column) (views:set-point! (view) (editing:line-position cart line column)))

(define (place)
  (let* ([doc (buffers:document cart)] [p (views:point (view))]) (list (document:line doc p) (document:column doc p 8))))

(define (crumbs) (status-line-test:segment-text (view) breadcrumb:path))

;; Any key ends in an idle period, after which outlines read are made.
(define (idle!) (test-user:press! "C-l"))

;; A read buffer edited is made again only by the next idle pass, the
;; same pass that would make any other outline read, so its asking shows
;; the pass is done.
(define witness (buffers:make "witness.toy" "class W\n"))
(modes:set-major-mode outline-test/toy:mode witness)

(define (idle-pass!)
  (outline:cached witness)
  (buffers:replace! witness 1 1 "x")
  (let ([asked (outline-test/toy:asked witness)])
    (idle!)
    (test-runner:wait-until (lambda () (> (outline-test/toy:asked witness) asked)))))

(define (crumbs-become text)
  (test-runner:wait-until (lambda () (equal? text (crumbs)))))

(define (segment-element)
  (find (lambda (e) (equal? "breadcrumb:path" (test-user:element-attribute e "data-segment")))
        (test-user:elements (status-line-test:footer (view)) "status-line-segment")))

(layout:switch-to-buffer cart)

(test "until its segment is placed nothing is shown and no outline is asked"
  (go! 3 4)
  (idle-pass!)
  (check-equal? #f (member "breadcrumb:path" (status-line-test:segment-names (view))))
  (check-equal? 0 (outline-test/toy:asked cart)))

(tables:set! status-line:segments breadcrumb:path (status-line:left 40))

(test "a buffer whose outline is not made shows nothing, and the draw, a read, has the outline made at the next idle; then the path shows, the innermost in breadcrumb-leaf"
  (go! 3 4)
  (check-equal? "" (crumbs))
  (idle!)
  (crumbs-become "Cart > total")
  (check-equal? '("total")
                (map test-user:element-text (test-user:elements (segment-element) "breadcrumb-leaf"))))

(test "with breadcrumb:depth 1 only the innermost entry shows"
  (options:set! breadcrumb:depth 1)
  (check-equal? "total" (crumbs))
  (options:unset! breadcrumb:depth))

(test "when point moves the path follows at the next draw"
  (go! 5 4)
  (check-equal? "Cart > add" (crumbs))
  (go! 7 2)
  (check-equal? "helper" (crumbs)))

(test "where point is in no entry, and in a buffer with no outline, nothing shows"
  (go! 1 2)
  (check-equal? "" (crumbs))
  (let ([plain (buffers:make "plain.txt" "plain text")])
    (layout:switch-to-buffer plain)
    (check-equal? "" (crumbs))
    (layout:switch-to-buffer cart)))

(test "an edit is followed through mapped ranges until the outline is made again at idle, which shows the new names"
  (options:set! outline:idle-delay 30)
  (go! 3 4)
  (let ([asked (outline-test/toy:asked cart)])
    (buffers:replace! cart (editing:line-position cart 1) (editing:line-position cart 1) "more notes\n")
    (check-equal? "Cart > total" (crumbs))
    (check-equal? asked (outline-test/toy:asked cart)))
  (options:set! outline:idle-delay 0.05)
  (let ([total (editing:line-position cart 4 9)])
    (buffers:replace! cart total (+ total 5) "sum"))
  (idle!)
  (crumbs-become "Cart > sum")
  (buffers:replace! cart (editing:line-position cart 1) (editing:line-position cart 2) "")
  (let ([sum (editing:line-position cart 3 9)])
    (buffers:replace! cart sum (+ sum 3) "total"))
  (idle!)
  (crumbs-become "Cart > total"))

(test "the segment's title says what a click does"
  (go! 3 4)
  (check-equal? '("mouse-1: go to total")
                (map (lambda (e) (test-user:element-attribute e "title")) (test-user:elements-with (segment-element) "title"))))

(define (other-view) (find (lambda (v) (not (eq? v (view)))) (layout:views)))

(test "mouse-1 on the path selects the view clicked and goes to the innermost entry's name there, recording the place left; mouse-3 goes to its end"
  (go! 4 6)
  (test-user:press! "C-x 2")
  (let ([clicked (other-view)])
    (views:set-point! clicked (editing:line-position cart 6 6))
    (status-line-test:click! clicked 1 breadcrumb:keymap)
    (check (eq? clicked (view)))
    (check-equal? '(5 9) (place))
    (test-user:press! "M-,")
    (check-equal? '(6 6) (place))
    (status-line-test:click! clicked 3 breadcrumb:keymap)
    (check-equal? '(6 8) (place)))
  (layout:reset-layout)
  (go! 4 6))

(test "mouse-2 on the path is the status line's own, which keeps only the clicked view, and moves no point"
  (go! 4 6)
  (test-user:press! "C-x 2")
  (let ([clicked (other-view)])
    (views:set-point! clicked (editing:line-position cart 6 6))
    (status-line-test:click! clicked 2 breadcrumb:keymap)
    (check-equal? (list clicked) (layout:views))
    (check-equal? '(6 6) (place))))

(test "a long path is drawn whole in one segment, which the line's stylesheet cuts"
  (let ([deep (buffers:make "deep.toy"
                (apply string-append (map (lambda (k) (format "~aclass c~a\n" (make-string (* 2 k) #\space) k)) (iota 12))))])
    (modes:set-major-mode outline-test/toy:mode deep)
    (layout:switch-to-buffer deep)
    (views:set-point! (view) (editing:line-position deep 12 25))
    (idle!)
    (test-runner:wait-until
      (lambda () (equal? "c0 > c1 > c2 > c3 > c4 > c5 > c6 > c7 > c8 > c9 > c10 > c11" (crumbs))))
    (layout:switch-to-buffer cart)))

(test "unloading breadcrumb takes its segment away, and the outline is read no longer"
  (go! 3 4)
  (crumbs)
  (unload-owner! (module-owner '(breadcrumb)))
  (check-equal? #f (member "breadcrumb:path" (status-line-test:segment-names (view))))
  (buffers:replace! cart (editing:line-position cart 1) (editing:line-position cart 1) "x")
  (idle-pass!)
  (let ([asked (outline-test/toy:asked cart)])
    (buffers:replace! cart (editing:line-position cart 1) (editing:line-position cart 1) "y")
    (idle-pass!)
    (check-equal? asked (outline-test/toy:asked cart))))
