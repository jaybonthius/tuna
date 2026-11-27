(import (tuna) (test) (layout) (layout-scroll) (views) (buffers) (document) (web) (test-user))

(define desktop (test-user:client))

(define (lines name n)
  (apply string-append (map (lambda (i) (format "~a ~a\n" name (+ i 1))) (iota n))))

(define (atom view . attributes)
  (views:view (cons* (cons 'view (views:id view)) (cons 'buffer (buffers:name (views:buffer view))) attributes)))

(define (set-parts! . parts)
  (let ([n (document:length (buffers:document layout:buffer))])
    (buffers:replace! layout:buffer 1 (- n 1) (apply document:from-datum parts)))
  (test-user:settle))

(define (number e name) (string->number (test-user:element-attribute e name)))

(define (scroller-element) (car (test-user:elements-with (test-user:screen desktop) "data-scroller")))

(define %reports 0)

(define (strip-report! items whole)
  (set! %reports (+ %reports 1))
  (let ([s (scroller-element)])
    (web:post-input! desktop
      `(("type" . "scroller") ("scroller" . ,(number s "data-scroller")) ("placement" . ,(number s "data-placement"))
        ("report" . ,%reports) ("items" . ,(list->vector items)) ("whole" . ,(list->vector whole)) ("settled" . #f))))
  (test-user:settle))

(define (bands)
  (map (lambda (band)
         (list (test-user:element-attribute band "class")
               (test-user:element-attribute band "aria-label")
               (length (test-user:elements band "strip-edge-card"))))
       (test-user:elements (test-user:screen desktop) "strip-edge")))

(define vs (map (lambda (name) (views:make (buffers:make (buffers:free-name name) (lines name 20)))) '("a" "b" "c" "d" "e")))

(define (id name) (views:id (list-ref vs (- (char->integer (string-ref name 0)) 97))))

(define (title name) (buffers:name (views:buffer (list-ref vs (- (char->integer (string-ref name 0)) 97)))))

(set-parts! (apply layout-scroll:container '() (map (lambda (v) (atom v '(size . 1/2))) vs)))
(layout:select! (list-ref vs 2))

(test "before a client reports, the columns drawn on each side of the focused one stand in for those wholly in view, so the bands are empty"
  (test-user:settle)
  (check-equal? '(("strip-edge start" #f 0) ("strip-edge end" #f 0)) (bands)))

(test "past an end with columns not wholly shown, the band is a button on the nearest, labelled with how many more lie past it, a card each up to three"
  (strip-report! (map id '("b" "c" "d")) (map id '("c")))
  (check-equal? `(("strip-edge start" ,(format "~a, and 1 more" (title "b")) 2) ("strip-edge end" ,(format "~a, and 1 more" (title "d")) 2))
                (bands))
  (strip-report! (map id '("a" "b")) (map id '("a" "b")))
  (check-equal? `(("strip-edge start" #f 0) ("strip-edge end" ,(format "~a, and 2 more" (title "c")) 3)) (bands))
  (strip-report! (map id '("a" "b")) (map id '("a")))
  (check-equal? `(("strip-edge start" #f 0) ("strip-edge end" ,(format "~a, and 3 more" (title "b")) 3)) (bands)))

(test "a column wider than the strip is never wholly shown, and the focused column stands in for it"
  (strip-report! (map id '("c")) '())
  (check-equal? `(("strip-edge start" ,(format "~a, and 1 more" (title "b")) 2) ("strip-edge end" ,(format "~a, and 1 more" (title "d")) 2))
                (bands)))

(test "a band names its column's positions and carries the layout's keymap, so a click on it selects that column"
  (let* ([band (car (test-user:elements (test-user:screen desktop) "strip-edge"))]
         [at (number band "data-at")]
         [mark (read (open-input-string (views:keymap-mark layout:keymap)))])
    (check-equal? 'button (car band))
    (check-equal? (views:keymap-mark layout:keymap) (test-user:element-attribute band "data-keymap"))
    (for-each
      (lambda (action)
        (web:post-input! desktop
          `(("type" . "mouse") ("action" . ,action) ("button" . 1) ("clicks" . 1) ("modifiers" . #())
            ("view" . ,(views:id layout:screen-view)) ("version" . ,(buffers:version layout:buffer))
            ("showing" . ,(views:shown-count layout:screen-view)) ("token" . ,at) ("keymaps" . ,(vector mark))))
        (test-user:settle))
      '("down" "click"))
    (check-equal? (id "b") (views:id (layout:selected-view)))
    (layout:select! (list-ref vs 2))
    (test-user:settle)))

(test "the box around the scroller and its bands carries the strip's direction and the classes layout gives the part"
  (check-equal? "layout-strip-box row focus-path"
                (test-user:element-attribute (car (test-user:elements (test-user:screen desktop) "layout-strip-box")) "class"))
  (set-parts! (apply layout-scroll:container '((direction . column)) (map (lambda (v) (atom v '(size . 1/2))) vs)))
  (check-equal? "layout-strip-box column"
                (substring (test-user:element-attribute (car (test-user:elements (test-user:screen desktop) "layout-strip-box")) "class")
                           0 23)))
