(import (tuna) (test) (test-runner) (layout) (layout-split) (layout-float) (views) (buffers) (document) (commands) (tables) (undo)
        (keys) (web) (test-user) (layout-float-test popper) (layout-float-test asker))

(define (raised-with who message)
  (lambda (e)
    (and (who-condition? e) (eq? who (condition-who e))
         (message-condition? e) (string=? message (condition-message e)))))

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

(define (shape-of datum)
  (let walk ([d datum])
    (if (vector? d)
        (let ([attributes (vector-ref d 1)])
          (cons (name-of (cdr (assq 'view attributes)))
                (remp (lambda (a) (memq (car a) '(view buffer))) attributes)))
        (cons* (car d) (cadr d) (map walk (cddr d))))))

(define (shape) (shape-of (car (document:datums (buffers:document layout:buffer)))))

(define (popups-datum) (car (document:datums (buffers:document layout:popups-buffer))))

(define (popups) (shape-of (popups-datum)))

(define (selected) (name-of (views:id (layout:selected-view))))

(define (press! keys) (test-user:press! desktop keys))

(define (reports-during thunk)
  (map (lambda (c) (list (condition-who c) (condition-message c))) (reverse (test-runner:reports-during thunk))))

(define (described floats)
  (map (lambda (f) (list (test-user:element-attribute f "class") (test-user:element-attribute f "style"))) floats))

(define (floats client)
  (described (test-user:elements (test-user:screen client) "float-child")))

(define (layout-floats client)
  (let* ([screen (test-user:screen client)]
         [popups (apply append (map (lambda (e) (test-user:elements e "float-child")) (test-user:elements screen "layout-popups")))])
    (described (remp (lambda (f) (memq f popups)) (test-user:elements screen "float-child")))))

(define a (buffers:make (buffers:free-name "a") (lines "a" 300)))
(define b (buffers:make (buffers:free-name "b") (lines "b" 20)))
(define va (named 'va (views:make a)))
(define vb (named 'vb (views:make b)))
(define vc (named 'vc (views:make b)))

(test "a float container draws its first child without a place as its base, and the others over it, placed and sized"
  (set-parts! (layout-float:container '() (atom va) (atom vb '(place box 1/4 3/4))
                (atom vc '(place box 1 0) '(width columns 30) '(height lines 8))))
  (layout:select! va)
  (test-user:settle)
  (check-equal?
    '(("float-child" "--layout-float-inline-size:50.0%;--layout-float-block-size:50.0%;--layout-float-x:0.25;--layout-float-y:0.75;--layout-float-z:1")
      ("float-child" "--layout-float-inline-size:calc(30ch + var(--layout-float-frame));--layout-float-block-size:calc(8lh + var(--layout-float-frame));--layout-float-x:1.0;--layout-float-y:0.0;--layout-float-z:2"))
    (floats desktop)))

(test "floats stack by their last selection, the latest on top, and selecting one raises it"
  (layout:select! vb)
  (test-user:settle)
  (check-equal? '("--layout-float-z:2" "--layout-float-z:1")
    (map (lambda (f) (let ([style (cadr f)]) (substring style (- (string-length style) 18) (string-length style))))
         (floats desktop)))
  (check-equal? '(vb va) (map (lambda (v) (name-of (views:id v))) (layout:selection-order))))

(test "from a float, left and right go to the floats before and after it in the layout, without wrapping; from the base nothing is beside it"
  (press! "s-l")
  (check-equal? 'vc (selected))
  (press! "s-l")
  (check-equal? 'vc (selected))
  (press! "s-j s-j")
  (check-equal? 'vb (selected))
  (layout:select! va)
  (press! "s-l")
  (check-equal? 'va (selected)))

(test "s-V selects the view selected last in the other layer: the floats from the base, the base from a float"
  (press! "s-V")
  (check-equal? 'vb (selected))
  (press! "s-V")
  (check-equal? 'va (selected)))

(test "s-v floats the selected view in the middle of the float container around it, as a new view at its point, and on a float puts it back"
  (views:set-point! va 40)
  (press! "s-v")
  (named 'floated (layout:selected-view))
  (check-equal? '((layout:level () (layout-float:container () (vb (place box 1/4 3/4)) (vc (place box 1 0) (width columns 30) (height lines 8))
                    (floated (place box 1/2 1/2) (width . 1/2) (height . 1/2))))
                  floated 40)
                (list (shape) (selected) (views:point (layout:selected-view))))
  (press! "s-v")
  (check-equal? '(layout:level () (layout-float:container () (vb (place box 1/4 3/4)) (vc (place box 1 0) (width columns 30) (height lines 8))))
                (shape))
  (check-equal? 40 (views:point (layout:selected-view)))
  (check-equal? a (views:buffer (layout:selected-view))))

(test "with no float container around the selected view, s-v makes one around its level's part, and window changes keep no undo history"
  (let ([vd (named 'vd (views:make a))] [other (named 'other (views:make b))])
    (set-parts! (layout-split:container '() (atom vd) (atom other)))
    (layout:select! vd)
    (press! "s-v")
    (named 'floated-d (layout:selected-view))
    (check-equal? '(layout:level () (layout-float:container () (other) (floated-d (place box 1/2 1/2) (width . 1/2) (height . 1/2))))
                  (shape))
    (check (buffers:silent? layout:buffer)))
  (let ([inner (named 'inner (views:make a))] [left (named 'left (views:make b))] [right (named 'right (views:make b))])
    (set-parts! (layout-split:container '() (atom left) (layout:level '() (layout-split:container '() (atom inner) (atom right)))))
    (layout:select! inner)
    (press! "s-v")
    (named 'floated-e (layout:selected-view))
    (check-equal? '(layout:level () (layout-split:container () (left)
                     (layout:level () (layout-float:container () (right) (floated-e (place box 1/2 1/2) (width . 1/2) (height . 1/2))))))
                  (shape))))

(define vd (named 'vd (views:make a)))
(define completions (buffers:make (buffers:free-name "*completions*") "one\ntwo\n"))
(define p #f)

(define (anchor-number)
  (caddr (assq 'place (vector-ref (caddr (caddr (popups-datum))) 1))))

(test "a popup is a float in the popups buffer, anchored at a position in a view's text, drawn after the layout and following edits"
  (set-parts! (atom vd))
  (layout:select! vd)
  (set! p (named 'p (layout-float:show-at! vd 7 completions 1/2 '(lines 4))))
  (test-user:settle)
  (let ([anchor (views:find-anchor (anchor-number))])
    (check-equal? (list 7 vd) (list (views:anchor-position anchor) (views:anchor-view anchor)))
    (let* ([screen (test-user:screen desktop)]
           [classes (map (lambda (e) (test-user:element-attribute e "class")) (test-user:elements-with screen "class"))])
      (check (member "layout-popups" (member "view-anchor" classes)))
      (check-equal? (list (list "float-child anchored"
                                (format "--layout-float-anchor:--view-anchor-~a;--layout-float-inline-size:50.0%;--layout-float-block-size:calc(4lh + var(--layout-float-frame));--layout-float-z:1"
                                        (anchor-number))))
                    (floats desktop)))
    (buffers:replace! a 1 1 "xy")
    (check-equal? 9 (views:anchor-position anchor))))

(test "the popups buffer keeps no undo history"
  (check-equal? 1 (length (cddr (undo:history layout:popups-buffer)))))

(test "showing the same buffer again moves its anchor"
  (check-equal? p (layout-float:show-at! vd 30 completions 1/2 '(lines 4)))
  (check-equal? 30 (views:anchor-position (views:find-anchor (anchor-number))))
  (check-equal? 1 (length (cddr (caddr (popups-datum))))))

(test "a popup is drawn only for a client whose drawn lines hold its anchor"
  (let ([drawn? (lambda (client) (pair? (test-user:elements (test-user:screen client) "anchored")))])
    (views:scroll-to! vd (document:line-start (buffers:document a) 290) (views:align top))
    (test-user:settle)
    (check-equal? '(#f #f) (list (drawn? desktop) (drawn? phone)))
    (views:scroll-to! vd 1 (views:align top))
    (test-user:settle)
    (check-equal? '(#t #t) (list (drawn? desktop) (drawn? phone)))))

(test "a popup can be selected, and a popup is locked; C-x o goes back to the layout, which a popup never leaves"
  (layout:select! p)
  (test-user:settle)
  (check-equal? (list 'p (list vd) #f) (list (selected) (layout:views) (layout:view-node p)))
  (press! "C-x 1")
  (check-equal? '((layout:delete-view "a locked part")) (reports-during (lambda () (press! "C-x 0"))))
  (press! "C-x o")
  (check-equal? 'vd (selected)))

(test "show-at! takes a view in the layout or a popup, a position in its buffer and a size"
  (check-raises (raised-with 'layout-float:show-at! "not a view in the layout or a popup") (layout-float:show-at! (views:make b) 0 b 1/2 1/2))
  (check-raises (raised-with 'layout-float:show-at! "not a position in the view's buffer") (layout-float:show-at! vd 100000 b 1/2 1/2))
  (check-raises (raised-with 'layout-float:show-at! "not a fraction, (columns n), (lines n) or content") (layout-float:show-at! vd 0 b 2 1/2)))

(test "close! removes a popup and its anchor, and the float container holding popups goes with the last"
  (let ([n (anchor-number)])
    (layout-float:close! p)
    (test-user:settle)
    (check-equal? '(layout:popups-root ()) (popups))
    (check-equal? #f (views:find-anchor n))
    (check-raises (raised-with 'views:id "a dropped view") (layout-float:close! p))))

(define ve (named 've (views:make b)))

(test "a popup goes when its anchor goes, or its anchor's view leaves the layout, by any edit"
  (layout-float:show-at! vd 5 completions '(columns 20) '(lines 4))
  (views:remove-anchor! (views:find-anchor (anchor-number)))
  (test-user:settle)
  (check-equal? '(layout:popups-root ()) (popups))
  (layout-float:show-at! vd 5 completions '(columns 20) '(lines 4))
  (set-parts! (atom ve))
  (check-equal? '(layout:popups-root ()) (popups)))

(define question (buffers:make (buffers:free-name "*question*") "Name: \n"))
(define pal #f)

(test "a palette floats at the top middle of the screen, over the layout, and showing it again gives the same"
  (set! pal (named 'pal (layout-float:display-palette question)))
  (test-user:settle)
  (check-equal? '(layout:popups-root () (layout-float:container () (pal (place box 1/2 1/5) (width . 3/5) (height lines 12) (locked . #t))))
                (popups))
  (check-equal? pal (layout-float:display-palette question)))

(test "selecting a popup records no use of its buffer, and C-x <left> and C-x <right> do not step through a popup's buffers"
  (layout:select! ve)
  (layout:select! pal)
  (test-user:settle)
  (check-equal? b (car (buffers:all)))
  (check-equal? pal (layout:selected-view))
  (check-raises (raised-with 'layout:previous-buffer "Cannot switch buffers in a popup") (layout:previous-buffer 1)))

(test "from a popup, the views C-x o visits start at the view of the layout selected last"
  (check-equal? ve (car (layout:other-views)))
  (layout:select! ve)
  (test-user:settle))

(test "the popups a module made go when it unloads"
  (call-as-owner (module-owner '(layout-float-test popper)) (lambda () (layout-float-test/popper:show! (layout:selected-view))))
  (test-user:settle)
  (check-equal? 2 (length (cddr (caddr (popups-datum)))))
  (unload-owner! (module-owner '(layout-float-test popper)))
  (test-user:settle)
  (check-equal? '(layout:popups-root () (layout-float:container () (pal (place box 1/2 1/5) (width . 3/5) (height lines 12) (locked . #t))))
                (popups)))

(test "a popup can be anchored in a popup's text, and one that moves goes after the others, so its anchor is drawn before it"
  (let* ([cp (named 'cp (layout-float:show-at! ve 2 completions 1/2 '(lines 4)))]
         [pal2 (named 'pal2 (layout-float:display-palette (buffers:make (buffers:free-name "*other*") "Find: \n")))])
    (check-equal? cp (layout-float:show-at! pal2 6 completions 1/2 '(lines 4)))
    (named 'deep (layout-float:show-at! cp 2 b 1/2 1/2))
    (test-user:settle)
    (check-equal? '(pal pal2 cp deep) (map car (cddr (caddr (popups)))))
    (check-equal? 2 (length (test-user:elements (test-user:screen desktop) "anchored")))
    (layout-float:close! pal2)
    (test-user:settle)
    (check-equal? '(layout:popups-root () (layout-float:container () (pal (place box 1/2 1/5) (width . 3/5) (height lines 12) (locked . #t))))
                  (popups))))

(test "a palette is never an anchored popup of the same buffer, nor the reverse"
  (let ([cp (layout-float:show-at! ve 2 completions 1/2 '(lines 4))])
    (check (not (eq? cp (layout-float:display-palette completions))))
    (check (not (eq? pal (layout-float:show-at! ve 1 question 1/2 1/2))))))

(test "s-v on a float that is a container puts back only the selected view, and the container collapses by layout's rules"
  (let ([vf (named 'vf (views:make b))] [vg (named 'vg (views:make a))])
    (set-parts! (layout-float:container '() (atom ve) (layout-split:container '((place box 1/2 1/2)) (atom vf) (atom vg))))
    (layout:select! vf)
    (press! "s-v")
    (check-equal? '((layout:level () (layout-float:container () (ve) (vg (place box 1/2 1/2)))) ve) (list (shape) (selected)))))

(define vh (named 'vh (views:make a)))

(test "a child after the base without a place floats at the centre, and the commands take it for a float"
  (let ([vi (named 'vi (views:make a))])
    (set-parts! (layout-float:container '() (atom ve) (atom vh) (atom vi '(place box 0 0))))
    (layout:select! vi)
    (press! "s-j")
    (check-equal? 'vh (selected))
    (press! "s-V")
    (check-equal? 've (selected))
    (press! "s-V")
    (check-equal? 'vh (selected))))

(test "a float whose anchor's number is unknown, as after a restart, is drawn at the centre"
  (set-parts! (layout-float:container '() (atom ve) (atom vh '(place anchor 999))))
  (check-equal? '(("float-child" "--layout-float-inline-size:50.0%;--layout-float-block-size:50.0%;--layout-float-x:0.5;--layout-float-y:0.5;--layout-float-z:1"))
                (layout-floats desktop)))

(test "a float may be as tall or as wide as what it draws, and carries a class saying so"
  (let* ([tall (buffers:make (buffers:free-name "*tall*") "Menu\n")]
         [tp (named 'tp (layout-float:display-palette tall 'content))])
    (test-user:settle)
    (check-equal? '(tp (place box 1/2 1/5) (width . 3/5) (height . content) (locked . #t)) (car (last-pair (caddr (popups)))))
    (set-parts! (layout-float:container '() (atom ve) (atom vh '(place box 0 1) '(height . content))
                  (atom (views:make tall) '(place box 1 0) '(width . content))))
    (check-equal? '(("float-child float-content-block-size" "--layout-float-inline-size:50.0%;--layout-float-block-size:auto;--layout-float-x:0.0;--layout-float-y:1.0;--layout-float-z:2")
                    ("float-child float-content-inline-size" "--layout-float-inline-size:fit-content;--layout-float-block-size:50.0%;--layout-float-x:1.0;--layout-float-y:0.0;--layout-float-z:1"))
                  (layout-floats desktop))
    (check-raises (raised-with 'layout-float:display-palette "not a fraction, (columns n), (lines n) or content")
                  (layout-float:display-palette tall '(lines 0)))))

(test "when layout-float unloads its popups go, and a module that showed one through a display rule unloads later quietly"
  (tables:set! layout:display-rules (lambda (b) (string=? (buffers:name b) "*asked*")) layout-float:display-palette)
  (call-as-owner (module-owner '(layout-float-test asker)) (lambda () (layout-float-test/asker:ask!)))
  (test-user:settle)
  (unload-owner! (module-owner '(layout-float)))
  (test-user:settle)
  (check-equal? '(layout:popups-root ()) (popups))
  (load-module! '(layout-float))
  (check-equal? '() (reports-during (lambda () (unload-owner! (module-owner '(layout-float-test asker))) (test-user:settle))))
  (check-equal? '(layout:popups-root ()) (popups)))

(test "every page links the floats' stylesheet"
  (check-equal? "layout-float/layout-float.css" (tables:ref web:stylesheets 'layout-float #f)))

(test "w f in the part mode wraps the selected part in a float container, as its base"
  (let ([vw (named 'vw (views:make a))])
    (set-parts! (atom vw))
    (layout:select! vw)
    (test-user:settle)
    (commands:run layout-float:wrap-in-float)
    (test-user:settle)
    (check-equal? '(layout:level () (layout-float:container () (vw))) (shape))
    (check-equal? layout-float:wrap-in-float (keys:lookup-in (list layout:part-mode-keymap) "w f"))))
