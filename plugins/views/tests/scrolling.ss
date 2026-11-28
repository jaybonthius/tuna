(import (tuna) (test) (test-runner) (views) (buffers) (document) (options) (commands) (keys) (layout) (web) (test-user)
        (views-test page) (views-test text) (views-test md))

(options:set! views:scroll-margin 2 views:wrap-lines #f)

(define desktop (views-test/page:open 400))
(define phone (views-test/page:open 200))

(define (client page) (views-test/page:client page))
(define (drawn page view) (views-test/page:drawn page view))
(define (placement page view) (views-test/page:placement page view))
(define report! views-test/page:report!)
(define (line-of v p) (views-test/text:line-of v p))
(define (line-start v n) (views-test/text:line-start v n))

(define (make-buffer name content) (buffers:make (buffers:free-name name) content))

(define (number e name) (string->number (test-user:element-attribute e name)))

;; A key pressed at a client moves point, so that client leads the view.
(define target 1)

(commands:define-command (go-to-target)
  "Moves point to the position the test chose."
  (views:set-point! (views:current) target))

(keys:bind! keys:global "C-c g" go-to-target)

(define (go-to! page position)
  (set! target position)
  (test-user:press! (client page) "C-c g"))

(define (go-to-line! page line) (go-to! page (line-start v line)))

(define v (layout:selected-view))
(define b (make-buffer "long" (views-test/text:lines 300)))
(views:set-buffer! v b)

(test "before its page reports a client is drawn 100 lines beyond each edge, and a new client is placed where the view is"
  (check-equal? '(1 101 101 () (199)) (drawn desktop v))
  (check-equal? '((new position 1) (new position 1)) (list (placement desktop v) (placement phone v))))

(test "a report names what the page wants beyond each edge, and its client is drawn that far"
  (report! desktop v 1 0 #f)
  (check-equal? '(1 59 59 () (241)) (drawn desktop v))
  (report! phone v 1 0 #f)
  (check-equal? '(1 29 29 () (271)) (drawn phone v)))

(test "a page whose top edge lies in a spacer names the line its counts put there, and is placed and drawn there"
  (report! desktop v 150 0 #f)
  (check-equal? '((new position 150) (same position 1) 1 (109 191 83 (108) (109)))
    (list (placement desktop v) (placement phone v) (line-of v (views:top v #f)) (drawn desktop v)))
  (report! desktop v 150 0 #f)
  (check-equal? '((same position 150) (111 208 98 (110) (92))) (list (placement desktop v) (drawn desktop v))))

(test "once a hand scroll comes to rest the view's place moves, every other client is placed there once, and point comes into view"
  (report! desktop v 151 5 #t)
  (check-equal? '((same position 151) (new position 151) 151 154)
    (list (placement desktop v) (placement phone v) (line-of v (views:top v #f)) (line-of v (views:point v))))
  (report! desktop v 151 5 #t)
  (check-equal? '((same position 151) (same position 151)) (list (placement desktop v) (placement phone v))))

(test "a page's report on its own placement does not move the view, so pages of different sizes never place each other"
  (report! phone v 151 5 #f)
  (report! phone v 151 5 #t)
  (check-equal? '((same position 151) (same position 151) 151)
    (list (placement desktop v) (placement phone v) (line-of v (views:top v #f)))))

(test "a report on an older placement than its client's newest is ignored, but its number comes back on the client's screen"
  (views:scroll-to! v (line-start v 200) (views:align top))
  (check-equal? '((new top 200) (new top 200)) (list (placement desktop v) (placement phone v)))
  (let ([newest (number (views-test/page:view-element phone v) "data-placement")])
    (report! phone v 20 0 #t (cons "placement" (- newest 1)) (cons "report" 99))
    (check-equal? 200 (line-of v (views:top v #f)))
    (check-equal? 99 (number (views-test/page:view-element phone v) "data-reported"))))

(test "a fling past what is drawn above reports from the spacer, and at rest the view goes there, point to the last line wholly in view"
  (report! desktop v 200 0 #f)
  (check-equal? '(161 258 98 (160) (42)) (drawn desktop v))
  (report! desktop v 60 7 #f)
  (check-equal? '((new position 60) (19 101 83 (18) (199)) 200 60)
    (list (placement desktop v) (drawn desktop v) (line-of v (views:top v #f)) (line-of v (views:top v (client desktop)))))
  (report! desktop v 60 7 #t)
  (check-equal? '(60 (new position 60) 77)
    (list (line-of v (views:top v #f)) (placement phone v) (line-of v (views:point v)))))

(test "a command that moves point has every client follow it, each in its own geometry"
  (go-to-line! phone 75)
  (check-equal? '((new follow 60) (new follow 151)) (list (placement desktop v) (placement phone v)))
  (report! phone v 68 0 #f)
  (report! desktop v 61 0 #f)
  (check-equal? '(61 68) (list (line-of v (views:top v (client desktop))) (line-of v (views:top v (client phone)))))
  (check-raises (test-runner:raised-with 'views:top "not a client or #f") (views:top v 'nobody)))

(test "a page that scrolled past every drawn line while following point names the place in the spacer, and leaves following"
  (report! desktop v 250 0 #f)
  (check-equal? '((new position 250) (209 291 83 (208) (9))) (list (placement desktop v) (drawn desktop v))))

(define (page-report-answer page view top start end)
  (lambda (name value)
    `(("report" . (("type" . "scroll") ("view" . ,(views:id view))
                   ("placement" . ,(number (views-test/page:shown-element page view) "data-placement"))
                   ("version" . 0) ("top" . (("line" . ,top))) ("spacer" . #f) ("fraction" . 0) ("left" . null)
                   ("past" . 0) ("sides" . #()) ("start" . (("line" . ,start))) ("end" . (("line" . ,end)))
                   ("atStart" . #f) ("atEnd" . #f) ("columns" . 80) ("rows" . 20) ("pointVisible" . #f)
                   ("wanted" . (("aboveLines" . 41) ("aboveChars" . 3280) ("belowLines" . 41) ("belowChars" . 3280)
                                ("side" . 160)))
                   ("hand" . #t) ("settled" . #t) ("edge" . "top") ("report" . 500))))))

(test "C-v asks the commanding client's page to scroll by its height, drawing more and asking again when it has too little"
  (let* ([asked '()] [report-answer (page-report-answer desktop v 268 270 285)])
    (views-test/page:set-answer! desktop
      (lambda (name value)
        (set! asked (cons (cdr (assoc "again" value)) asked))
        (if (and (equal? name "views-page") (not (cdr (assoc "again" value))) (cdr (assoc "forward" value)))
            '(("more" . #t))
            (report-answer name value))))
    (test-user:press! (client desktop) "C-v")
    (check-equal? '((#f #t) 268 (new position 268) 270)
      (list (reverse asked) (line-of v (views:top v #f)) (placement phone v) (line-of v (views:point v))))))

(test "with a prefix C-v asks for that many lines, the other way when negative, and with - a page the other way"
  (let* ([steps '()] [report-answer (page-report-answer desktop v 268 270 285)])
    (views-test/page:set-answer! desktop
      (lambda (name value)
        (set! steps (cons (map (lambda (key) (cdr (assoc key value))) '("forward" "by")) steps))
        (report-answer name value)))
    (test-user:press! (client desktop) "C-u 3 C-v")
    (test-user:press! (client desktop) "M-- 3 C-v")
    (test-user:press! (client desktop) "M-- C-v")
    (check-equal? '((#t 3) (#f 3) (#f null)) (reverse steps))))

(test "a view draws a vertical scroll bar, and each drawn item counts the characters before it, from which the page sizes the thumb"
  (let* ([e (views-test/page:view-element desktop v)]
         [bars (lambda (e) (map (lambda (bar) (test-user:element-attribute bar "data-scroll-bar"))
                                (test-user:elements e "view-scroll-bar")))]
         [first-line (car (filter (lambda (l) (equal? "line" (test-user:element-attribute l "class")))
                                  (test-user:elements e "line")))])
    (check-equal? '("vertical") (bars e))
    (check-equal? (document:offset (buffers:document b) (line-start v (number first-line "data-line")) (document:unit characters))
                  (number first-line "data-before"))
    (views:set-option! v views:vertical-scroll-bar #f)
    (views:set-option! v views:horizontal-scroll-bar #t)
    (check-equal? '("horizontal") (bars (views-test/page:view-element desktop v)))
    (views:remove-option! v views:vertical-scroll-bar)
    (views:remove-option! v views:horizontal-scroll-bar)))

(define (mark-number keymap) (read (open-input-string (views:keymap-mark keymap))))

(define (press-bar! page part keymap)
  (for-each
    (lambda (action)
      (web:post-input! (client page)
        `(("type" . "mouse") ("action" . ,action) ("button" . 1) ("clicks" . 1) ("modifiers" . #())
          ("view" . ,(views:id v)) ("version" . ,(buffers:version b)) ("showing" . ,(views:shown-count v))
          ("line" . 100) ("chars" . 3) ("keymaps" . ,(vector (mark-number keymap)))
          ,@(if part `(("part" . ,part)) '())))
      (test-user:settle))
    '("down" "click")))

(test "a press on the bar off its thumb scrolls a page toward its part, as Emacs's toolkit bar does; a press with no part does nothing"
  (let* ([steps '()] [report-answer (page-report-answer desktop v 268 270 285)])
    (views-test/page:set-answer! desktop
      (lambda (name value)
        (set! steps (cons (map (lambda (key) (cdr (assoc key value))) '("forward" "by")) steps))
        (report-answer name value)))
    (press-bar! desktop "below-handle" views:scroll-bar-keymap)
    (press-bar! desktop "above-handle" views:scroll-bar-keymap)
    (press-bar! desktop #f views:scroll-bar-keymap)
    (check-equal? '((#t null) (#f null)) (reverse steps))))

(test "a press on the horizontal bar off its thumb scrolls the lines sideways toward its part, as C-x < and C-x > do; a press with no part does nothing"
  (let* ([steps '()] [report-answer (page-report-answer desktop v 268 270 285)])
    (views-test/page:set-answer! desktop
      (lambda (name value)
        (set! steps (cons (map (lambda (key) (cdr (assoc key value))) '("sideways" "forward" "context" "by")) steps))
        (report-answer name value)))
    (press-bar! desktop "after-handle" views:horizontal-scroll-bar-keymap)
    (press-bar! desktop "before-handle" views:horizontal-scroll-bar-keymap)
    (press-bar! desktop #f views:horizontal-scroll-bar-keymap)
    (check-equal? '((#t #t 2 null) (#t #f 2 null)) (reverse steps))))

(test "a mouse key on the bar names the part the page drew it in"
  (let* ([parts '()]
         [note (lambda (next event) (set! parts (cons (views:posn-part (keys:event-start event)) parts)) (next event))])
    (views-test/page:set-answer! desktop (page-report-answer desktop v 268 270 285))
    (advice-add! views:scroll-bar-scroll note)
    (press-bar! desktop "above-handle" views:scroll-bar-keymap)
    (advice-remove! views:scroll-bar-scroll note)
    (check-equal? (list (views:bar-part above-handle)) parts)))

(test "M-r moves point to the middle row the page names, then the top and bottom rows past the scroll margin; with a prefix, that row"
  (let ([rows-asked '()])
    (views-test/page:set-answer! desktop
      (lambda (name value)
        (let ([r (cdr (assoc "row" value))])
          (set! rows-asked (cons r rows-asked))
          `(("version" . 0) ("at" . (("line" . ,(+ 270 (cond [(eq? r 'null) 10] [(< r 0) (+ 20 r)] [else r])))))))))
    (test-user:press! (client desktop) "M-r")
    (check-equal? 280 (line-of v (views:point v)))
    (test-user:press! (client desktop) "M-r")
    (check-equal? 272 (line-of v (views:point v)))
    (test-user:press! (client desktop) "M-r")
    (check-equal? 287 (line-of v (views:point v)))
    (test-user:press! (client desktop) "C-u 5 M-r")
    (check-equal? 275 (line-of v (views:point v)))
    (check-equal? '(null 2 -3 5) (reverse rows-asked))
    (check-equal? 289 (line-of v (views:row-start v (client desktop) -1)))))

(test "C-l puts point's place at the centre, then the top, then the bottom, marked where the place is while it is newest"
  (go-to-line! desktop 70)
  (test-user:press! (client desktop) "C-l")
  (check-equal? '(new center 70) (placement desktop v))
  (let ([marked (test-user:elements (views-test/page:view-element desktop v) "view-place")])
    (check-equal? 1 (length marked)))
  (test-user:press! (client desktop) "C-l")
  (check-equal? '(new top 70) (placement desktop v))
  (test-user:press! (client desktop) "C-l")
  (check-equal? '(new bottom 70) (placement desktop v)))

(test "with a number C-l puts point on that row, counted from 0 at the top or from -1 at the bottom, and with C-u alone at the centre"
  (define (placed)
    (append (placement desktop v)
            (list (test-user:element-attribute (views-test/page:view-element desktop v) "data-place-rows"))))
  (go-to-line! desktop 70)
  (test-user:press! (client desktop) "C-u 2 C-l")
  (check-equal? '(new top 70 "2") (placed))
  (test-user:press! (client desktop) "C-u - 2 C-l")
  (check-equal? '(new bottom 70 "1") (placed))
  (test-user:press! (client desktop) "M-- C-l")
  (check-equal? '(new bottom 70 "0") (placed))
  (test-user:press! (client desktop) "C-u C-l")
  (check-equal? '(new center 70 #f) (placed))
  (check-raises (test-runner:raised-with 'views:recenter-top-bottom "not a prefix argument") (views:recenter-top-bottom 'top)))

(test "work no client did places every client"
  (views:scroll-to! v (line-start v 10) (views:align top))
  (check-equal? '((new top 10) (new top 10)) (list (placement desktop v) (placement phone v))))

(test "showing another buffer forgets what every page reported"
  (report! phone v 100 0 #f)
  (views:set-buffer! v (make-buffer "short" (views-test/text:lines 30)))
  (check-equal? '(1 31 31 () ()) (drawn phone v))
  (views:set-buffer! v b))

(test "an item keeps its element's id while text is inserted above it"
  (let ([id-of-line (lambda (line)
                      (test-user:element-attribute
                        (find (lambda (l) (equal? (number->string line) (test-user:element-attribute l "data-line")))
                              (test-user:elements (views-test/page:view-element phone v) "line"))
                        "id"))])
    (report! phone v 1 0 #f)
    (let ([before (id-of-line 20)])
      (buffers:replace! b (line-start v 2) (line-start v 2) "new\nlines\n")
      (check-equal? before (id-of-line 22)))))

(test "with a huge drawn-screens a client draws every item"
  (views:set-option! v views:drawn-screens 1e300)
  (report! phone v 1 0 #f (cons "wanted" '(("aboveLines" . 99999999) ("aboveChars" . 99999999) ("belowLines" . 99999999)
                                           ("belowChars" . 99999999) ("side" . 99999999))))
  (check-equal? '(1 303 303 () ()) (drawn phone v))
  (views:remove-option! v views:drawn-screens))

(test "a report that is not one is refused, and changes nothing"
  (let ([before (views:top v (client phone))]
        [refused (lambda (post!)
                   (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
                     (advice-add! report keep)
                     (post!)
                     (advice-remove! report keep)
                     (map (lambda (c) (list (condition-who c) (condition-message c))) reported)))])
    (check-equal? '((views "not a scroll report"))
      (refused (lambda () (web:post-input! (client phone) '(("type" . "scroll") ("view" . 1))) (test-user:settle))))
    (for-each
      (lambda (override)
        (check-equal? '((views "not a scroll report")) (refused (lambda () (report! phone v 150 0 #t override)))))
      (list '("top" . (("line" . 0))) '("fraction" . 2) '("spacer" . 1) '("sides" . #(1)) '("top" . (("chars" . -1)))))
    (check-equal? before (views:top v (client phone)))))

(test "an alignment is one of views:align's"
  (check-raises (test-runner:raised-with 'views:scroll-to! "not an alignment") (views:scroll-to! v 1 'middle)))

(test "where lines do not wrap, the column at the left edge is counted on the line the page names, long lines are drawn around their edges, and set-hscroll! places every client"
  (let* ([wide (make-buffer "wide" (string-append (make-string 3000 #\a) "\n" (make-string 3000 #\x4E00) "\nshort\n"))]
         [s (views:make wide)]
         [segments (lambda (line)
                     (let ([l (find (lambda (l) (equal? (number->string line) (test-user:element-attribute l "data-line")))
                                    (test-user:elements (views-test/page:view-element desktop s) "line"))])
                       (map (lambda (g) (number g "data-segment")) (test-user:elements-with l "data-segment"))))])
    (report! desktop s 1 0 #t (cons "left" '(("at" . 1) ("count" . 2000)))
             (cons "sides" (vector (vector '(("at" . 1) ("count" . 2000)) '(("at" . 1) ("count" . 2080)))
                                   (vector '(("at" . 3002) ("count" . 1000)) '(("at" . 3002) ("count" . 1040))))))
    (check-equal? '(2000 1) (call-with-values (lambda () (views:hscroll s)) list))
    (check-equal? '((0 3 4) (1 2)) (list (segments 1) (segments 2)))
    (let ([placed-column (lambda (page)
                           (let ([e (views-test/page:view-element page s)])
                             (list (number e "data-place-column") (number e "data-place-column-item"))))])
      (views:set-hscroll! s 0)
      (check-equal? '((0 1) (0 1)) (list (placed-column desktop) (placed-column phone)))
      (views:set-hscroll! s 10 3500)
      (check-equal? '((10 3002) (10 3002)) (list (placed-column desktop) (placed-column phone))))
    (check-raises (test-runner:raised-with 'views:set-hscroll! "not a position in the view's buffer") (views:set-hscroll! s 10 40000))))

(test "C-x < asks the commanding client's page to scroll sideways by its width less two columns, or by a prefix, and takes its report"
  (let* ([wide (make-buffer "wide" (string-append (make-string 3000 #\a) "\n" (make-string 3000 #\x4E00) "\nshort\n"))]
         [asked #f])
    (views:set-buffer! v wide)
    (views-test/page:set-answer! desktop
      (lambda (name value)
        (set! asked (map (lambda (key) (cdr (assoc key value))) '("sideways" "forward" "context" "by")))
        `(("report" . (("type" . "scroll") ("view" . ,(views:id v))
                       ("placement" . ,(number (views-test/page:shown-element desktop v) "data-placement"))
                       ("version" . 0) ("top" . (("line" . 1))) ("spacer" . #f) ("fraction" . 0)
                       ("left" . (("at" . 1) ("count" . 2078))) ("past" . 0) ("sides" . #()) ("start" . (("line" . 1)))
                       ("end" . (("line" . 3))) ("atStart" . #t) ("atEnd" . #t) ("columns" . 80) ("rows" . 20)
                       ("pointVisible" . #t)
                       ("wanted" . (("aboveLines" . 41) ("aboveChars" . 3280) ("belowLines" . 41) ("belowChars" . 3280)
                                    ("side" . 160)))
                       ("hand" . #t) ("settled" . #t) ("edge" . "top") ("report" . 501))))))
    (test-user:press! (client desktop) "C-x <")
    (check-equal? '(#t #t 2 null) asked)
    (check-equal? '(2078 1) (call-with-values (lambda () (views:hscroll v)) list))
    (let ([e (views-test/page:view-element phone v)])
      (check-equal? '(2078 1) (list (number e "data-place-column") (number e "data-place-column-item"))))
    (test-user:press! (client desktop) "M-- 5 C-x <")
    (check-equal? '(#t #f 2 5) asked)
    (views:set-buffer! v b)))

(test "where lines wrap, a run that starts at a later segment of a long line draws a gap standing for the characters before it"
  (let ([one-line (make-buffer "one-line" (string-append (make-string 100000 #\a) "\n"))])
    (views:set-buffer! v one-line)
    (views:set-option! v views:wrap-lines #t)
    (go-to! desktop 60000)
    (let* ([e (views-test/page:view-element desktop v)] [gap (car (test-user:elements e "view-gap"))])
      (check-equal? '("1" "39424") (list (test-user:element-attribute gap "data-line") (test-user:element-attribute gap "data-chars")))
      (check-equal? 77 (number (car (test-user:elements-with e "data-segment")) "data-segment"))
      (check-equal? '(1 100001) (list (number e "data-lines") (number e "data-chars"))))
    (views:remove-option! v views:wrap-lines)
    (views:set-buffer! v b)))

(test "a view draws for a client or for none"
  (check-raises (test-runner:raised-with 'views:draw "not a client or #f") (views:draw v 'nobody)))

(test "a run's edges fall only between items, so a whole node is drawn all or not at all, and a run after it starts with it"
  (let* ([long (make-buffer "long-page"
                 (apply views-test/md:doc '()
                   (append (map (lambda (i) (views-test/md:para '() (format "para ~a\n" i))) (iota 50))
                           (list (apply views-test/md:grid '()
                                   (map (lambda (i) (views-test/md:para '() (format "cell ~a\n" i))) (iota 30))))
                           (map (lambda (i) (views-test/md:para '() (format "after ~a\n" i))) (iota 50)))))]
         [w (views:make long)])
    (views:set-option! w views:drawn-screens 0.5)
    (report! phone w 1 0 #f)
    (check-equal? '(1 15 15 () (115)) (drawn phone w))
    (report! phone w 40 0 #f)
    (report! phone w 40 0 #f)
    (check-equal? '(36 80 45 (35) (50)) (drawn phone w))
    (report! phone w 82 0 #f)
    (check-equal? '(51 89 39 (50) (41)) (drawn phone w))))

(test "following? holds while the view follows point, and not after a hand scroll at rest or an alignment"
  (views:set-buffer! v b)
  (go-to-line! desktop 30)
  (check (views:following? v))
  (report! desktop v 40 0 #t)
  (check (not (views:following? v)))
  (go-to-line! desktop 45)
  (check (views:following? v))
  (views:scroll-to! v (line-start v 45) (views:align top))
  (check (not (views:following? v))))

(test "rows-shown gives the starts of the first and last rows wholly in view past the scroll margin, as the page last reported them"
  (report! desktop v 40 0 #t)
  (check-equal? '(42 57) (call-with-values (lambda () (views:rows-shown v (client desktop)))
                           (lambda (first last) (list (line-of v first) (line-of v last)))))
  (let ([fresh (views-test/page:open 400)])
    (check-equal? '(#f #f) (call-with-values (lambda () (views:rows-shown v (client fresh))) list))))

(test "with tail on, a view a page left at its end follows the end, and every other page keeps it at the bottom edge"
  (let ([log (make-buffer "log" (views-test/text:lines 30))])
    (views:set-buffer! v log)
    (buffers:with-buffer log (options:set-local! views:tail #t))
    (check (test-user:element-attribute (views-test/page:view-element phone v) "data-tail"))
    (report! phone v 22 0 #t (cons "atEnd" #t))
    (check (views:following? v))
    (let ([e (views-test/page:view-element desktop v)])
      (check-equal? '("follow" "bottom")
        (list (test-user:element-attribute e "data-place-kind") (test-user:element-attribute e "data-place-edge"))))
    (views:set-buffer! v b)))

(define (reports-during thunk)
  (map (lambda (c) (list (condition-who c) (condition-message c))) (test-runner:reports-during thunk)))

(test "M-v asks the page to scroll back, and C-v and M-v raise at the end and the start the page reports"
  (let ([asked '()])
    (views-test/page:set-answer! desktop
      (lambda (name value)
        (set! asked (cons (cdr (assoc "forward" value)) asked))
        '(("limit" . #t))))
    (check-equal? '((views:scroll-down "beginning of buffer"))
                  (reports-during (lambda () (test-user:press! (client desktop) "M-v"))))
    (check-equal? '((views:scroll-up "end of buffer"))
                  (reports-during (lambda () (test-user:press! (client desktop) "C-v"))))
    (check-equal? '(#f #t) (reverse asked))))

(test "C-x > asks the page to scroll the lines right, sideways and back"
  (let ([asked #f])
    (views-test/page:set-answer! desktop
      (lambda (name value)
        (set! asked (map (lambda (key) (cdr (assoc key value))) '("sideways" "forward")))
        '(("limit" . #t))))
    (reports-during (lambda () (test-user:press! (client desktop) "C-x >")))
    (check-equal? '(#t #f) asked)))
