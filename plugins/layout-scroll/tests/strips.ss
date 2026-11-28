(import (tuna) (test) (test-runner) (layout) (layout-split) (layout-scroll) (layout-tabs) (views) (buffers) (document) (commands)
        (tables) (keys) (web) (test-user))

(define desktop (test-user:client))
(define phone (test-user:open-client))

(define (lines name n)
  (apply string-append (map (lambda (i) (format "~a ~a\n" name (+ i 1))) (iota n))))

(define names '())

(define (named name view)
  (set! names (cons (cons (views:id view) name) names))
  view)

(define (name-of id) (cond [(assv id names) => cdr] [else id]))

(define (atom view . attributes)
  (views:view (cons* (cons 'view (views:id view)) (cons 'buffer (buffers:name (views:buffer view))) attributes)))

(define (set-parts! . parts)
  (let ([n (document:length (buffers:document layout:buffer))])
    (buffers:replace! layout:buffer 1 (- n 1) (apply document:from-datum parts)))
  (test-user:settle))

(define (shape)
  (let walk ([d (car (document:datums (buffers:document layout:buffer)))])
    (if (vector? d)
        (let ([attributes (vector-ref d 1)])
          (cons (name-of (cdr (assq 'view attributes)))
                (remp (lambda (a) (memq (car a) '(view buffer))) attributes)))
        (cons* (car d) (cadr d) (map walk (cddr d))))))

(define (selected) (name-of (views:id (layout:selected-view))))

(define (press! client keys) (test-user:press! client keys))

(define (refusals keys) (test-runner:shown-reports-during (lambda () (press! desktop keys))))

(define (number e name) (string->number (test-user:element-attribute e name)))

(define (scroller-element client)
  (car (test-user:elements-with (test-user:screen client) "data-scroller")))

(define (strip client)
  (let ([s (scroller-element client)])
    (list (name-of (number s "data-place-item")) (string->symbol (test-user:element-attribute s "data-place-align"))
          (name-of (number s "data-place-focus"))
          (map (lambda (item)
                 (let ([id (name-of (number item "data-item"))])
                   (if (null? (test-user:elements item "strip-placeholder")) id (list id 'placeholder))))
               (test-user:elements s "strip-item")))))

(define %reports 0)

(define (strip-report! client items . rest)
  (let ([s (scroller-element client)])
    (set! %reports (+ %reports 1))
    (web:post-input! client
      (append `(("type" . "scroller") ("scroller" . ,(number s "data-scroller"))
                ("placement" . ,(number s "data-placement")) ("report" . ,%reports)
                ("items" . ,(list->vector items)) ("whole" . ,(list->vector items)) ("settled" . ,(pair? rest)))
              (if (pair? rest) `(("item" . ,(car rest)) ("align" . ,(cadr rest)) ("focus" . ,(caddr rest))) '())))
    (test-user:settle)))

(define a (buffers:make (buffers:free-name "a") (lines "a" 50)))
(define b (buffers:make (buffers:free-name "b") (lines "b" 50)))
(define c (buffers:make (buffers:free-name "c") (lines "c" 50)))
(define d (buffers:make (buffers:free-name "d") (lines "d" 50)))
(define va (named 'va (views:make a)))
(define vb (named 'vb (views:make b)))
(define vc (named 'vc (views:make c)))
(define vd (named 'vd (views:make d)))
(define ve (named 've (views:make d)))

(test "a strip holds columns, each a fraction of its length, and a column is any part"
  (set-parts! (layout-scroll:container '() (atom va '(size . 1/2))
                (layout-split:container '((direction . column) (size . 1/3)) (atom vb) (atom vc)) (atom vd) (atom ve '(size . 2/3))))
  (layout:select! vb)
  (test-user:settle)
  (check-equal? '(layout:level () (layout-scroll:container () (va (size . 1/2))
                   (layout-split:container ((direction . column) (size . 1/3)) (vb) (vc)) (vd) (ve (size . 2/3))))
                (shape)))

(test "each column is an item named by its view selected last; before a client has measured the strip it draws the focused column and enough on each side"
  (check-equal? '(vb nearest vb (va vb vd ve)) (strip desktop)))

(test "s-l moves the focus right, the strip places the new focus for every client, and the ends do not wrap"
  (press! desktop "s-l")
  (check-equal? '(vd (vd nearest vd (va vb vd ve)) (vd nearest vd (va vb vd ve))) (list (selected) (strip desktop) (strip phone)))
  (press! desktop "s-l s-l s-l")
  (check-equal? 've (selected))
  (press! desktop "s-j s-<left>")
  (check-equal? 'vb (selected)))

(test "within a column split s-k and s-i move down and up"
  (press! desktop "s-k")
  (check-equal? 'vc (selected))
  (press! desktop "s-i")
  (check-equal? 'vb (selected)))

(test "once a client has reported what is in view it draws only that and the focused column, the rest placeholders showing their part's title"
  (strip-report! desktop (list (views:id vb) (views:id vd)))
  (check-equal? '(vb nearest vb ((va placeholder) vb vd (ve placeholder))) (strip desktop))
  (let ([placeholder (car (test-user:elements (test-user:screen desktop) "strip-placeholder"))])
    (check-equal? (buffers:name a) (test-user:element-text placeholder))
    (check-equal? (views:keymap-mark layout:keymap) (test-user:element-attribute placeholder "data-keymap")))
  (check-equal? '(vb nearest vb (va vb vd ve)) (strip phone)))

(test "a hand scroll that comes to rest moves the shared focus to the column it settled on, and every other client is placed there"
  (let ([before (number (scroller-element phone) "data-placement")])
    (strip-report! phone (list (views:id vd)) (views:id vd) "start" (views:id vd))
    (check-equal? 'vd (selected))
    (check-equal? before (number (scroller-element phone) "data-placement"))
    (check-equal? '(vd start vd ((va placeholder) vb vd (ve placeholder))) (strip desktop))))

(test "a report while scrolling only tells what is in view on that client"
  (strip-report! desktop (list (views:id vd) (views:id ve)))
  (check-equal? '(vd (vd start vd ((va placeholder) (vb placeholder) vd ve))) (list (selected) (strip desktop))))

(test "s-<home> and s-<end> select the first and last column, and s-c centres the focused column"
  (press! desktop "s-<home>")
  (check-equal? 'va (selected))
  (press! desktop "s-<end>")
  (check-equal? 've (selected))
  (press! desktop "s-c")
  (check-equal? '(ve center ve ((va placeholder) (vb placeholder) vd ve)) (strip desktop)))

(define (strip-parts) (cddr (caddr (car (document:datums (buffers:document layout:buffer))))))

(define (part-attributes part) (if (vector? part) (vector-ref part 1) (cadr part)))

(define (sizes)
  (map (lambda (part) (let ([s (assq 'size (part-attributes part))]) (and s (cdr s)))) (strip-parts)))

(test "s-r and s-R step through the size presets, from a size between them to the next larger; C-s-f fills the strip, and again the default size"
  (layout:select! vd)
  (test-user:settle)
  (check-equal? '(1/2 1/3 #f 2/3) (sizes))
  (press! desktop "s-r")
  (check-equal? '(1/2 1/3 2/3 2/3) (sizes))
  (press! desktop "s-r s-r")
  (check-equal? '(1/2 1/3 1/2 2/3) (sizes))
  (press! desktop "s-R")
  (check-equal? '(1/2 1/3 1/3 2/3) (sizes))
  (press! desktop "C-s-f")
  (check-equal? '(1/2 1/3 1 2/3) (sizes))
  (press! desktop "C-s-f")
  (check-equal? '(1/2 1/3 1/2 2/3) (sizes)))

(test "s-, moves the next column into the focused one, making a column split of a lone view, and s-. moves the last part out"
  (press! desktop "s-,")
  (check-equal? '(layout:level () (layout-scroll:container () (va (size . 1/2))
                   (layout-split:container ((direction . column) (size . 1/3)) (vb) (vc))
                   (layout-split:container ((direction . column) (size . 1/2)) (vd) (ve))))
                (shape))
  (press! desktop "s-.")
  (check-equal? '(layout:level () (layout-scroll:container () (va (size . 1/2))
                   (layout-split:container ((direction . column) (size . 1/3)) (vb) (vc)) (vd (size . 1/2)) (ve (size . 1/2))))
                (shape)))

(test "s-[ and s-] move a view sharing its column out into a new one on that side, and a lone view into the neighbouring column"
  (layout:select! vb)
  (press! desktop "s-]")
  (check-equal? '(layout:level () (layout-scroll:container () (va (size . 1/2)) (vc (size . 1/3)) (vb (size . 1/2))
                   (vd (size . 1/2)) (ve (size . 1/2))))
                (shape))
  (press! desktop "s-[")
  (check-equal? '(layout:level () (layout-scroll:container () (va (size . 1/2))
                   (layout-split:container ((direction . column) (size . 1/3)) (vc) (vb)) (vd (size . 1/2)) (ve (size . 1/2))))
                (shape))
  (layout:select! va)
  (press! desktop "s-]")
  (check-equal? '(layout:level () (layout-scroll:container ()
                   (layout-split:container ((direction . column) (size . 1/3)) (vc) (vb) (va)) (vd (size . 1/2)) (ve (size . 1/2))))
                (shape))
  (check-equal? 'va (selected)))

(test "the display action adds a column after the selected view's and selects it, and outside a strip it declines"
  (let* ([e (buffers:make (buffers:free-name "e") "e\n")]
         [new (named 'new (layout-scroll:display-in-new-column e))])
    (test-user:settle)
    (check-equal? 'new (selected))
    (check-equal? '(layout-split:container new vd ve) (map car (cddr (caddr (shape)))))
    (check-raises (test-runner:raised-with 'layout-scroll:add-column! "not a view in the layout") (layout-scroll:add-column! (views:make e) e))
    (check-raises (test-runner:raised-with 'layout-scroll:display-in-new-column "not a buffer") (layout-scroll:display-in-new-column "e"))
    (set-parts! (atom va))
    (layout:select! va)
    (check-equal? '((layout-scroll:cycle-size "the selected view is in no strip"))
                  (test-runner:shown-reports-during (lambda () (commands:run layout-scroll:cycle-size))))
    (check-equal? #f (layout-scroll:display-in-new-column e))))

(test "the commands refuse to change a locked strip"
  (let ([vf (views:make b)])
    (set-parts! (layout-split:container '() (layout-scroll:container '((locked . #t)) (atom va) (atom vf)) (atom (views:make c))))
    (layout:select! va)
    (check-equal? '((layout-scroll:consume "a locked part")) (refusals "s-,"))
    (check-equal? '((layout-scroll:full-size "a locked part")) (refusals "C-s-f"))))

(define vg (named 'vg (views:make c)))
(define vh (named 'vh (views:make d)))

(test "a column strip lays its children top to bottom, s-k and s-i move along it, and its element says so"
  (set-parts! (layout-scroll:container '((direction . column)) (atom va) (atom vg) (atom vh)))
  (layout:select! va)
  (press! desktop "s-k")
  (check-equal? 'vg (selected))
  (press! desktop "s-l")
  (check-equal? 'vg (selected))
  (let ([s (scroller-element desktop)])
    (check-equal? "layout-strip column" (test-user:element-attribute s "class"))
    (check-equal? "column" (test-user:element-attribute s "data-axis"))))

(test "with center always, a command places the focus in the middle"
  (set-parts! (layout-scroll:container '((center . always)) (atom va) (atom vg) (atom vh)))
  (layout:select! vg)
  (test-user:settle)
  (check-equal? '(vg center vg (va vg vh)) (strip desktop))
  (check-equal? "layout-strip row center" (test-user:element-attribute (scroller-element desktop) "class")))

(test "s-] on a view deeper in its column moves the part holding it out, and the split left with one part collapses as layout collapses it"
  (let ([vj (named 'vj (views:make a))])
    (set-parts! (layout-scroll:container '() (atom va)
                  (layout-split:container '((direction . column) (size . 1/3)) (atom vg '(weight . 2))
                    (layout-split:container '() (atom vh) (atom vj)))))
    (layout:select! vh)
    (press! desktop "s-]")
    (check-equal? '(layout:level () (layout-scroll:container () (va) (vg (size . 1/3))
                     (layout-split:container ((size . 1/2)) (vh) (vj))))
                  (shape))
    (check-equal? 'vh (selected))))

(test "a locked column is neither changed, moved nor merged into"
  (set-parts! (layout-scroll:container '() (atom va) (atom vg '(locked . #t)) (atom vh)))
  (layout:select! va)
  (check-equal? '((layout-scroll:consume "a locked part")) (refusals "s-,"))
  (check-equal? '((layout-scroll:consume-or-expel-right "a locked part")) (refusals "s-]"))
  (layout:select! vh)
  (check-equal? '((layout-scroll:consume-or-expel-left "a locked part")) (refusals "s-["))
  (set-parts! (layout-scroll:container '() (atom va) (layout-split:container '((direction . column)) (atom vg) (atom vh '(locked . #t)))))
  (layout:select! vg)
  (check-equal? '((layout-scroll:expel "a locked part")) (refusals "s-."))
  (check-equal? '(layout:level () (layout-scroll:container () (va)
                   (layout-split:container ((direction . column)) (vg) (vh (locked . #t)))))
                (shape)))

(test "s-. moves out the last part of a column of any kind, and tabs left with one tab stay, since that kind does not collapse"
  (set-parts! (layout-scroll:container '() (atom va) (layout-tabs:container '((size . 1/3)) (atom vg) (atom vh))))
  (layout:select! vg)
  (press! desktop "s-.")
  (check-equal? '(layout:level () (layout-scroll:container () (va) (layout-tabs:container ((size . 1/3)) (vg)) (vh (size . 1/2))))
                (shape))
  (check-equal? 'vg (selected)))

(test "a strip's size is a fraction, columns along a row strip or lines along a column strip, or its content's length"
  (let ([vk (views:make a)])
    (set-parts! (layout-scroll:container '() (atom va '(size columns 40)) (atom vg '(size lines 5)) (atom vh '(size . content))
                  (atom vk '(size . 1/4))))
    (check-equal? '("--layout-scroll-size:40ch" "--layout-scroll-size:50.0%" "--layout-scroll-size:max-content"
                    "--layout-scroll-size:25.0%")
                  (map (lambda (item) (test-user:element-attribute item "style"))
                       (test-user:elements (scroller-element desktop) "strip-item")))
    (layout:select! vg)
    (press! desktop "s-r")
    (check-equal? '((size columns 40) (size . 2/3) (size . content) (size . 1/4))
                  (map (lambda (part) (assq 'size (part-attributes part))) (strip-parts)))))

(test "every page links the strips' stylesheet"
  (check-equal? "layout-scroll/layout-scroll.css" (tables:ref web:stylesheets 'layout-scroll #f)))

(test "w s in the part mode wraps the selected part in a strip"
  (set-parts! (atom va))
  (layout:select! va)
  (test-user:settle)
  (commands:run layout-scroll:wrap-in-strip)
  (test-user:settle)
  (check-equal? '(layout:level () (layout-scroll:container () (va))) (shape))
  (check-equal? layout-scroll:wrap-in-strip (keys:lookup-in (list layout:part-mode-keymap) "w s")))

(define (unnamed-view) (find (lambda (v) (not (assv (views:id v) names))) (layout:views)))

(test "C-x 3 in a row strip adds a column after the selected one, of the default size, showing its buffer at its point, and C-x 2 splits the column across"
  (let ([vi (named 'vi (views:make a))] [vj (named 'vj (views:make b))])
    (set-parts! (layout-scroll:container '() (atom vi '(size . 1/3)) (atom vj)))
    (layout:select! vi)
    (views:set-point! vi 20)
    (press! desktop "C-x 3")
    (let ([new (named 'vi-new (unnamed-view))])
      (check-equal? '(layout:level () (layout-scroll:container () (vi (size . 1/3)) (vi-new (size . 1/2)) (vj))) (shape))
      (check-equal? (list 'vi 20 a) (list (selected) (views:point new) (views:buffer new))))
    (press! desktop "C-x 2")
    (named 'vi-below (unnamed-view))
    (check-equal? '(layout:level () (layout-scroll:container ()
                     (layout-split:container ((direction . column) (size . 1/3)) (vi) (vi-below)) (vi-new (size . 1/2)) (vj)))
                  (shape))))

(test "C-x 2 in a column strip adds an item after the selected one, and C-x 3 splits the item across"
  (let ([vk (named 'vk (views:make a))] [vl (named 'vl (views:make b))])
    (set-parts! (layout-scroll:container '((direction . column)) (atom vk) (atom vl)))
    (layout:select! vk)
    (press! desktop "C-x 2")
    (named 'vk-new (unnamed-view))
    (check-equal? '(layout:level () (layout-scroll:container ((direction . column)) (vk) (vk-new (size . 1/2)) (vl))) (shape))
    (press! desktop "C-x 3")
    (named 'vk-right (unnamed-view))
    (check-equal? '(layout:level () (layout-scroll:container ((direction . column))
                     (layout-split:container ((direction . row)) (vk) (vk-right)) (vk-new (size . 1/2)) (vl)))
                  (shape))))

(test "C-x 3 in a view of a column split by C-x 2 adds a column after that column, as in a column of one view"
  (let ([vm (named 'vm (views:make a))] [vn (named 'vn (views:make b))])
    (set-parts! (layout-scroll:container '() (atom vm '(size . 1/3)) (atom vn)))
    (layout:select! vm)
    (press! desktop "C-x 2")
    (named 'vm-below (unnamed-view))
    (press! desktop "C-x 3")
    (named 'vm-right (unnamed-view))
    (check-equal? '(layout:level () (layout-scroll:container ()
                     (layout-split:container ((direction . column) (size . 1/3)) (vm) (vm-below)) (vm-right (size . 1/2)) (vn)))
                  (shape))))

(test "a prefix to C-x 3 or C-x 2 sizes the part the new column went beside, a strip's split column too"
  (let ([vo (named 'vo (views:make a))] [vp (named 'vp (views:make b))])
    (set-parts! (layout-scroll:container '() (atom vo '(size . 1/3)) (atom vp)))
    (layout:select! vo)
    (press! desktop "C-x 2")
    (named 'vo-below (unnamed-view))
    (press! desktop "C-u 4 0 C-x 3")
    (named 'vo-right (unnamed-view))
    (check-equal? '(layout:level () (layout-scroll:container ()
                     (layout-split:container ((direction . column) (size columns 40)) (vo) (vo-below)) (vo-right (size . 1/2)) (vp)))
                  (shape)))
  (let ([vq (named 'vq (views:make a))] [vr (named 'vr (views:make b))])
    (set-parts! (layout-scroll:container '((direction . column)) (atom vq) (atom vr)))
    (layout:select! vq)
    (press! desktop "C-x 3")
    (named 'vq-right (unnamed-view))
    (press! desktop "C-u 6 C-x 2")
    (named 'vq-below (unnamed-view))
    (check-equal? '(layout:level () (layout-scroll:container ((direction . column))
                     (layout-split:container ((direction . row) (size lines 6)) (vq) (vq-right)) (vq-below (size . 1/2)) (vr)))
                  (shape))))
