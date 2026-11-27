(import (tuna) (test) (test-user) (layout) (layout-split) (layout-tabs) (layout-scroll) (layout-float) (echo-area) (minibuffer)
        (status-line) (views) (buffers) (document) (web)
        (layout-test parts) (layout-test focus))

(define atom layout-test/parts:atom)
(define view-named layout-test/focus:view-named)
(define reset! layout-test/focus:reset!)
(define begin! layout-test/focus:begin!)
(define made-beside layout-test/focus:made-beside)
(define selected layout-test/focus:selected)
(define shown layout-test/focus:shown)
(define who layout-test/focus:who)
(define enclosing layout-test/focus:enclosing)

(define (select-in-order! . vs) (for-each layout:select! vs))

(define (start-of n) (document:node-start n))

(define a #f)
(define b #f)
(define p #f)

(define (holding-locked! make-part)
  (set! a (view-named "a"))
  (set! b (view-named "b"))
  (set! p (view-named "p"))
  (reset! (make-part))
  (select-in-order! b p a))

(define (column-of-locked)
  (layout-split:container '((direction . column)) (atom b) (atom p '(locked . #t))))

(test "a part leads to its view used last that is not locked, so a Super move reaches a part whose last selected view is locked"
  (holding-locked! (lambda () (layout-split:container '((direction . row)) (atom a) (column-of-locked))))
  (test-user:press! "s-<right>")
  (check-equal? "b" (selected))
  (layout:select! p)
  (check-equal? "b" (who (layout:part-view (enclosing b)))))

(define (strip-of-locked)
  (layout-scroll:container '() (atom a '(size . 1/2))
    (layout-split:container '((direction . column) (size . 1/2)) (atom p '(locked . #t)) (atom b))))

(define reports 0)

;; A strip draws a column its page has not reported in view as a
;; placeholder, and the column past the last it shows whole as a band.
(define (report-strip-shows! v)
  (test-user:settle)
  (set! reports (+ reports 1))
  (let ([strip (car (test-user:elements (test-user:screen) "layout-strip"))] [ids (vector (views:id v))])
    (web:post-input! (test-user:client)
      (list (cons "type" "scroller")
            (cons "scroller" (string->number (test-user:element-attribute strip "data-scroller")))
            (cons "placement" (string->number (test-user:element-attribute strip "data-placement")))
            (cons "report" reports) (cons "items" ids) (cons "whole" ids) (cons "settled" #f))))
  (test-user:settle))

(test "a click on a strip column's placeholder or band names the column, and the strip's first and last moves reach it"
  (holding-locked! strip-of-locked)
  (report-strip-shows! a)
  (test-user:click-element! (layout-test/parts:marked-element "strip-placeholder" (start-of (enclosing b))))
  (check-equal? "b" (selected))
  (holding-locked! strip-of-locked)
  (report-strip-shows! a)
  (test-user:click-element! (layout-test/parts:marked-element "strip-edge" (start-of (enclosing b))))
  (check-equal? "b" (selected))
  (layout:select! p)
  (layout:select! a)
  (test-user:press! "s-<end>")
  (check-equal? "b" (selected))
  (layout:select! p)
  (test-user:press! "s-<home>")
  (check-equal? "a" (selected)))

(test "a hand scroll that comes to rest on a column selects its view that is not locked"
  (holding-locked! strip-of-locked)
  (test-user:settle)
  (let ([strip (car (test-user:elements (test-user:screen) "layout-strip"))] [focus (views:id b)])
    (web:post-input! (test-user:client)
      (list (cons "type" "scroller")
            (cons "scroller" (string->number (test-user:element-attribute strip "data-scroller")))
            (cons "placement" (string->number (test-user:element-attribute strip "data-placement")))
            (cons "report" 1) (cons "items" (vector focus)) (cons "whole" (vector focus)) (cons "settled" #t)
            (cons "item" focus) (cons "align" "start") (cons "focus" focus)))
    (test-user:settle)
    (check-equal? "b" (selected))))

(test "C-x t o, and a click on a tab's label, reach a tab whose last selected view is locked"
  (holding-locked! (lambda () (layout-tabs:container '() (atom a) (column-of-locked))))
  (test-user:press! "C-x t o")
  (check-equal? "b" (selected))
  (holding-locked! (lambda () (layout-tabs:container '() (atom a) (column-of-locked))))
  (test-user:settle)
  (test-user:click-element!
    (car (test-user:elements (layout-test/parts:marked-element "tab" (start-of (enclosing b))) "layout-tabs-label")))
  (check-equal? "b" (selected)))

(define (float-layers)
  (test-user:settle)
  (map (lambda (e)
         (let* ([style (test-user:element-attribute e "style")] [key "--layout-float-z:"]
                [at (let loop ([i 0]) (if (string=? key (substring style i (+ i (string-length key)))) (+ i (string-length key)) (loop (+ i 1))))])
           (let loop ([j at])
             (if (and (< j (string-length style)) (char-numeric? (string-ref style j)))
                 (loop (+ j 1))
                 (string->number (substring style at j))))))
       (test-user:elements (test-user:screen) "float-child")))

(test "the float holding the selected view is drawn on top though the view is locked, and s-V goes to the float drawn on top"
  (let ([c (view-named "c")])
    (holding-locked!
      (lambda ()
        (layout-float:container '() (atom a)
          (layout-split:container '((direction . column) (place box 1/4 1/4)) (atom p '(locked . #t)) (atom b))
          (atom c '(place box 3/4 3/4)))))
    (select-in-order! b c p)
    (check-equal? '(2 1) (float-layers))
    (layout:select! a)
    (test-user:press! "s-V")
    (check-equal? "b" (selected))))

(test "the part mode's r on a locked part beside the selected view deletes the view; its level keeps only the locked part, so the successor comes from the level around it"
  (let ([l (view-named "l")] [a (view-named "a")] [x (view-named "x")])
    (reset! (layout-split:container '((direction . row))
              (layout:level '() (layout-split:container '((direction . row)) (atom l '(locked . #t)) (atom a)))
              (atom x)))
    (select-in-order! x a)
    (test-user:press! "s-' j")
    (check-equal? "l" (who (layout:part-view (layout:selected-part))))
    (test-user:press! "r RET")
    (check-equal? '("x" ("l" "echo" "x")) (list (selected) (shown)))))

(test "the close button of the tab the user was in, clicked while a prompt waits, leaves the prompt selected, and C-g selects the tab left, not a part beside the user's level"
  (let ([a (view-named "a")] [b (view-named "b")])
    (reset! (layout-tabs:container '() (atom a) (atom b)))
    (let ([explorer (layout-test/focus:explorer!)])
      (select-in-order! b explorer a)
      (layout-test/focus:ask!)
      (test-user:settle)
      (test-user:click-element!
        (car (test-user:elements (layout-test/parts:marked-element "tab" (start-of (layout:view-node a))) "layout-tabs-close")))
      (check-equal? '(" *Minibuf*" ("explorer" "b" "echo" " *Minibuf*")) (list (selected) (shown)))
      (layout-test/focus:end-prompt!)
      (check-equal? "b" (selected)))))

(define scrolled '())

(define (note-scroll scroll . args)
  (set! scrolled (cons (who (views:current)) scrolled))
  (apply scroll args))

(test "C-M-v from a prompt scrolls the view the prompt came from"
  (let* ([a (begin! "a")] [b (begin (test-user:press! "C-x 3") (made-beside a "b"))])
    (test-user:press! "C-x o")
    (layout-test/focus:ask!)
    (set! scrolled '())
    (advice-add! views:scroll-up note-scroll)
    (test-user:press! "C-M-v")
    (advice-remove! views:scroll-up note-scroll)
    (check-equal? '("b") scrolled)
    (layout-test/focus:end-prompt!)))
