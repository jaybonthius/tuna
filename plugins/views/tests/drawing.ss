(import (tuna) (test) (test-runner) (views) (buffers) (document) (options) (tables) (haml) (test-user)
        (views-test page) (views-test md) (views-test lists) (views-test magit))

(options:set! views:scroll-margin 2 views:wrap-lines #f)

(buffers:define-layer hints)
(buffers:define-layer marks (priority 10))

(define (raised-with who message)
  (lambda (e)
    (and (who-condition? e) (eq? who (condition-who e))
         (message-condition? e) (string=? message (condition-message e)))))

(define (drawn v) (views-test/page:element-for-no-client v))

(define (attribute e name) (test-user:element-attribute e name))

(define (number e name) (string->number (attribute e name)))

(define (lines-of e)
  (filter (lambda (l) (equal? "line" (attribute l "class"))) (test-user:elements e "line")))

(define (texts es) (map test-user:element-text es))

(define (classes es) (map (lambda (e) (attribute e "class")) es))

(define (ranges es) (map (lambda (e) (list (number e "data-at") (number e "data-to"))) es))

(define (faces e)
  (map (lambda (f) (list (attribute f "data-face") (test-user:element-text f)))
       (test-user:elements-with e "data-face")))

(define (view-ids e) (map (lambda (v) (number v "data-view")) (test-user:elements e "view")))

(define (make-buffer name content) (buffers:make (buffers:free-name name) content))

(define (kinds-buffer)
  (make-buffer "m"
    (views-test/md:doc '()
      (views-test/md:heading '() "Title\n")
      (views-test/md:para '() "Alpha " (views-test/md:link '((href . "https://x")) "beta") " gamma.\n")
      (views-test/lists:bulleted '() (views-test/lists:item '() "one\n") (views-test/lists:item '() "two\n"))
      (views-test/md:para '() "Last " (views-test/md:image '((src . "a.png"))) " line.\n"))))

(test "each node draws by its kind, text as lines, an inline node inside its line and an atom where it stands"
  (let* ([v (views:make (kinds-buffer))] [e (drawn v)] [lines (lines-of e)])
    (check-equal? '("Title" "Alpha beta gamma." "one" "two" "Last  line.") (texts lines))
    (check-equal? 1 (length (test-user:elements e "md-doc")))
    (check-equal? '("Title") (texts (test-user:elements e "heading")))
    (check-equal? '("beta") (texts (test-user:elements (cadr lines) "md-link")))
    (check-equal? "https://x" (attribute (car (test-user:elements e "md-link")) "href"))
    (check-equal? '("one" "two") (texts (test-user:elements e "list-item")))
    (check-equal? '("a.png") (map (lambda (i) (attribute i "src")) (test-user:elements (list-ref lines 4) "md-image")))
    (check-equal? '((1 9) (9 31) (16 22) (31 45) (32 38) (38 44) (45 60) (51 52)) (ranges (test-user:elements e "node")))
    (check-equal? '("T") (texts (test-user:elements e "cursor-on")))))

(test "a link not sticky at its edges keeps the cursor before it or inside it, where its own draw shows it"
  (let ([v (views:make (kinds-buffer))])
    (views:set-point! v 17)
    (check-equal? 16 (views:point v))
    (let ([e (drawn v)])
      (check-equal? '("cursor primary") (classes (test-user:elements e "cursor")))
      (check-equal? '() (test-user:elements (car (test-user:elements e "md-link")) "cursor")))
    (views:set-point! v 20)
    (let ([e (drawn v)])
      (check-equal? '("a") (texts (test-user:elements (car (test-user:elements e "md-link")) "cursor-on"))))))

(test "every cursor shows, the primary marked, and a region covers the text between a cursor's point and mark"
  (let ([v (views:make (kinds-buffer))])
    (views:set-point! v 20)
    (views:add-cursor! v 22)
    (views:set-mark! v 13)
    (let ([e (drawn v)])
      (check-equal? '("ha " "bet") (texts (test-user:elements e "region")))
      (check-equal? '("cursor-on primary" "cursor-on") (classes (test-user:elements e "cursor-on")))
      (check-equal? '("a" " ") (texts (test-user:elements e "cursor-on"))))))

(test "a node whose kind is undefined draws as its content, as a block or inline where it sits"
  (let* ([v (views:make (kinds-buffer))]
         [u (views:make (make-buffer "u" (views-test/md:doc '() (views-test/md:para '() "x " (views-test/lists:item '() "y") "\n"))))])
    (unload-owner! (module-owner '(views-test lists)))
    (let ([undefined (test-user:elements (drawn v) "undefined-kind")])
      (check-equal? '(div div div) (map car undefined))
      (check-equal? '("onetwo" "one" "two") (texts undefined)))
    (let ([undefined (test-user:elements (drawn u) "undefined-kind")])
      (check-equal? '(span) (map car undefined))
      (check-equal? '("y") (texts undefined)))))

(test "a draw procedure that raises is reported, and the node draws as its content"
  (let* ([v (views:make (make-buffer "b" (views-test/md:doc '() (views-test/md:broken '() "oops\n"))))]
         [e #f]
         [reported (test-runner:reports-during (lambda () (set! e (drawn v))))])
    (check-equal? 1 (length reported))
    (check-equal? 'car (condition-who (car reported)))
    (check-equal? '("oops") (texts (test-user:elements e "undefined-kind")))))

(test "two text nodes on one line get distinct ids"
  (let* ([v (views:make (make-buffer "chat" (views-test/md:doc '() (views-test/md:para '() "Hello.")
                                                                  (views-test/md:para '() "How can I help?"))))]
         [lines (lines-of (drawn v))])
    (check-equal? '("Hello." "How can I help?") (texts lines))
    (check-equal? '("1" "1") (map (lambda (l) (attribute l "data-line")) lines))
    (check (not (equal? (attribute (car lines) "id") (attribute (cadr lines) "id"))))))

(test "an empty buffer draws one empty line holding the cursor"
  (let ([lines (lines-of (drawn (views:make (make-buffer "empty" ""))))])
    (check-equal? '("") (texts lines))
    (check-equal? '("cursor primary") (classes (test-user:elements (car lines) "cursor")))))

(define (spans-buffer)
  (make-buffer "notes" "Buy milk today.\nAnd bread.\n"))

(define (add-spans! notes n)
  (buffers:add-span! (buffers:layer notes hints) 5 5 '((before . "[x] ")))
  (buffers:add-span! (buffers:layer notes hints) 10 15 '((replace . "now") (face . date)))
  (buffers:add-span! (buffers:layer notes hints) 1 4 `((after . ,(views-test/md:image '((src . "b.png")))) (face . verb)))
  (buffers:add-span! (buffers:layer notes marks) 2 9 '((face . (strong mark)) (title . "a \"quote\" & <tag>")))
  (buffers:add-span! (buffers:layer notes hints n) 17 20 '((face . mine))))

(test "spans draw their faces, a list of faces nested, the first innermost, with the span's other attributes outermost"
  (let* ([notes (spans-buffer)] [n (views:make notes)])
    (add-spans! notes n)
    (let* ([e (drawn n)] [faced (test-user:elements-with e "data-face")])
      (check-equal? '(("verb" "Buy") ("mark" "uy") ("strong" "uy") ("mark" " [x] milk") ("strong" " [x] milk")
                      ("date" "now") ("mine" "And"))
                    (faces e))
      (check-equal? '("a \"quote\" & <tag>" #f "a \"quote\" & <tag>" #f)
                    (map (lambda (f) (attribute f "title")) (list-head (cdr faced) 4)))
      (check-equal? '("verb" "mark" "strong") (map (lambda (f) (attribute f "data-face")) (test-user:elements-with (car faced) "data-face")))
      (check-equal? '((4 4 "") (5 5 "[x] ") (10 15 "now"))
        (map (lambda (d) (list (number d "data-at") (number d "data-to") (test-user:element-text d)))
             (test-user:elements e "datum")))
      (check-equal? '("b.png") (map (lambda (i) (attribute i "src")) (test-user:elements e "md-image"))))
    (check-equal? #f (assoc "mine" (faces (drawn (views:make notes)))))))

(test "a span-properties entry that raises goes to report, and its span draws without it"
  (let* ([notes (spans-buffer)] [n (views:make notes)])
    (add-spans! notes n)
    (tables:set! views:span-properties 'bad (lambda (v) (car v)))
    (buffers:add-span! (buffers:layer notes marks) 18 19 '((bad . 1)))
    (let* ([e #f] [reported (test-runner:reports-during (lambda () (set! e (drawn n))))])
      (check-equal? 1 (length reported))
      (check-equal? 'car (condition-who (car reported)))
      (check-equal? "And bread." (test-user:element-text (cadr (lines-of e)))))
    (tables:remove! views:span-properties 'bad)))

(test "a span-properties entry that returns no list of attribute names and values goes to report once a draw"
  (let* ([notes (spans-buffer)] [n (views:make notes)])
    (tables:set! views:span-properties 'odd (lambda (v) (list 5 (cons "ok" "y"))))
    (buffers:add-span! (buffers:layer notes marks) 17 18 '((odd . 1)))
    (buffers:add-span! (buffers:layer notes marks) 19 20 '((odd . 2)))
    (let* ([e #f] [reported (test-runner:reports-during (lambda () (set! e (drawn n))))])
      (check-equal? 1 (length reported))
      (check ((raised-with 'views:span-properties "not a list of attribute names and values") (car reported)))
      (check-equal? '(odd (5 ("ok" . "y"))) (condition-irritants (car reported)))
      (check-equal? "And bread." (test-user:element-text (cadr (lines-of e)))))
    (tables:remove! views:span-properties 'odd)))

(test "a view atom draws the view it names; a second atom naming it gets a copy with its cursors; a number naming no view gets a view of that number"
  (let* ([buy (make-buffer "buy" "Buy milk.\n")]
         [first (views:make buy)]
         [host (make-buffer "host"
                 (views-test/md:doc '()
                   (views:view `((view . ,(views:id first)) (buffer . ,(buffers:name buy))))
                   (views:view `((view . ,(views:id first)) (buffer . ,(buffers:name buy))))
                   (views:view `((view . 70) (buffer . ,(buffers:name buy))))
                   (views:view `((buffer . ,(buffers:name buy))))))]
         [lv (views:make host)])
    (views:set-point! first 5)
    ;; A view atom is claimed per batch by the first to draw or ask for
    ;; it, so each step is a batch of its own, as the layout's draws are.
    (let* ([ids (view-ids (drawn lv))]
           [again (begin (test-user:settle) (view-ids (drawn lv)))]
           [doc (begin (test-user:settle) (buffers:document host))]
           [atoms (map (lambda (p) (views:id (views:atom-view (document:token doc p)))) '(1 2 3 4))])
      (check-equal? (cons (views:id lv) atoms) ids)
      (check-equal? ids again)
      (check-equal? (views:id first) (car atoms))
      (check-equal? 70 (caddr atoms))
      (check-equal? '(5 5 1 1) (map (lambda (id) (views:point (views:find id))) atoms))
      (check (< 70 (cadddr atoms))))))

(test "a view atom inside its own buffer draws its view once"
  (let* ([self (buffers:free-name "self")]
         [v (views:make (buffers:make self (views-test/md:doc '() (views:view `((buffer . ,self))))))])
    (check-equal? 2 (length (view-ids (drawn v))))))

(test "atom-view takes a view atom's node"
  (let ([b (make-buffer "plain" "Buy\n")])
    (check-raises (raised-with 'views:atom-view "not a node") (views:atom-view (document:token (buffers:document b) 1)))))

(test "atoms naming one view at one position in two buffers draw the view and a copy"
  (let* ([buy (make-buffer "buy" "Buy milk.\n")]
         [first (views:make buy)]
         [atom (lambda () (views:view `((view . ,(views:id first)) (buffer . ,(buffers:name buy)))))]
         [one (views:make (make-buffer "one" (views-test/md:doc '() (atom))))]
         [two (views:make (make-buffer "two" (views-test/md:doc '() (atom))))])
    (test-user:settle)
    (let* ([in-one (cadr (view-ids (drawn one)))] [in-two (cadr (view-ids (drawn two)))])
      (check-equal? (views:id first) in-one)
      (check (not (= in-one in-two))))))

(test "draw-children outside a draw draws a node's lines, and wrap receives each child, a line by its start"
  (let* ([notes (spans-buffer)] [n (views:make notes)]
         [children (views:draw-children n (document:token (buffers:document notes) 0)
                     (lambda (child html) (haml (:p.wrapped ([data-child (format "~a" child)]) html))))]
         [wrapped (test-user:elements (views-test/page:shown (haml (:div children))) "wrapped")])
    (check-equal? '("1" "17" "28") (map (lambda (w) (attribute w "data-child")) wrapped))
    (check-equal? '("Buy milk today." "And bread." "") (texts wrapped))))

(test "a byte that is not UTF-8 draws as a backslash and three octal digits in the face escape-glyph, one position each"
  (let* ([raw (make-buffer "raw" (list 'buffers:text '() "caf" (vector 'document:raw-byte '((byte . 233))) " "
                                       (vector 'document:raw-byte '((byte . 7))) "\n"))]
         [rv (views:make raw)])
    (views:set-point! rv 6)
    (let ([e (drawn rv)])
      (check-equal? '(("escape-glyph" "\\351") ("escape-glyph" "\\007")) (faces e))
      (check-equal? '((4 5) (6 7)) (ranges (test-user:elements e "node")))
      (check-equal? '("cursor primary") (classes (test-user:elements e "cursor"))))))

(test "a control character other than a tab or a line break draws as ^ and a character in the face escape-glyph, one position"
  (let* ([ctl (make-buffer "ctl" "a\rb\x0;\x7f;\x1b;\tc\nx\x7;y\nz\x1f;w\n")]
         [v (views:make ctl)])
    (buffers:add-span! (buffers:layer ctl hints) 14 17 '((face . keyword)))
    (views:set-point! v 3)
    (let* ([e (drawn v)] [glyphs (filter (lambda (f) (equal? "escape-glyph" (attribute f "data-face")))
                                         (test-user:elements-with e "data-face"))])
      (check-equal? '("a^Mb^@^?^[\tc" "x^Gy" "z^_w" "") (texts (lines-of e)))
      (check-equal? '("^M" "^@^?^[" "^G" "^_") (texts glyphs))
      (check-equal? '((2 3) (4 7) (11 12) (15 16)) (ranges glyphs))
      (check-equal? '(("keyword" "z^_w")) (filter (lambda (f) (equal? "keyword" (car f))) (faces e))))))

(define (pictures-buffer)
  (make-buffer "pictures"
    (views-test/md:doc '() (views-test/md:heading '() "a\n") (views-test/md:image '()) (views-test/md:image '())
                           (views-test/md:heading '() "b\n"))))

(test "a cursor right before an item standing alone is drawn on the item, and another cursor there leaves it the primary's"
  (let ([x (views:make (pictures-buffer))])
    (views:set-point! x 4)
    (check-equal? '("node whole at-cursor primary" "node whole") (classes (test-user:elements (drawn x) "whole")))
    (views:add-cursor! x 6)
    (check-equal? '("node whole at-cursor primary" "node whole at-cursor") (classes (test-user:elements (drawn x) "whole")))
    (views:add-cursor! x 4)
    (check-equal? 3 (length (views:cursors x)))
    (check-equal? '("node whole at-cursor primary" "node whole at-cursor") (classes (test-user:elements (drawn x) "whole")))))

(test "a cursor before an atom that draws no element stays a bar"
  (let ([y (views:make (make-buffer "blanks" (views-test/md:doc '() (views-test/md:heading '() "a\n") (views-test/md:blank '())
                                                                    (views-test/md:heading '() "b\n"))))])
    (views:set-point! y 4)
    (let ([e (drawn y)])
      (check-equal? '("cursor primary") (classes (test-user:elements e "cursor")))
      (check-equal? '("node whole") (classes (test-user:elements e "whole"))))))

(test "with cursor-visible #f a view draws no cursor, bar or outline, and still draws the region"
  (let ([x (views:make (pictures-buffer))])
    (views:set-point! x 4)
    (views:add-cursor! x 6)
    (views:set-option! x views:cursor-visible #f)
    (let ([e (drawn x)])
      (check-equal? '() (test-user:elements e "at-cursor"))
      (check-equal? '() (test-user:elements e "cursor-on"))
      (check-equal? '() (test-user:elements e "cursor")))
    (views:remove-cursor! x (cadr (views:cursors x)))
    (views:set-point! x 2)
    (views:set-mark! x 3)
    (check-equal? '("a") (texts (test-user:elements (drawn x) "region")))))

(test "a kind's draw procedure draws its node's content with draw-children, wrapping each child"
  (let* ([status (make-buffer "*status*"
                   (views-test/magit:section '()
                     (views-test/magit:section '() (buffers:text '() "Head: main\n"))
                     (views-test/magit:section '() (buffers:text '() "Untracked\n"))))]
         [e (drawn (views:make status))])
    (check-equal? 3 (length (test-user:elements e "magit-section")))
    (check-equal? '("Head: main" "Head: main" "Untracked" "Untracked") (texts (test-user:elements e "child")))
    (check-equal? '("Head: main" "Untracked") (texts (lines-of e)))))

(test "span-properties maps a key of a span's value to attributes of its element"
  (let* ([notes (make-buffer "notes" "* Today: Buy milk.\n")] [v (views:make notes)])
    (tables:set! views:span-properties 'tag (lambda (v) (list (cons "data-tag" v))))
    (buffers:add-span! (buffers:layer notes hints) 3 8 '((tag . "when") (face . bold)))
    (let ([tagged (test-user:elements-with (drawn v) "data-tag")])
      (check-equal? '("when") (map (lambda (t) (attribute t "data-tag")) tagged))
      (check-equal? '("bold") (map (lambda (t) (attribute t "data-face")) tagged))
      (check-equal? '("Today") (texts tagged)))
    (tables:remove! views:span-properties 'tag)))

(test "a view's element has the class nowrap while its lines do not wrap, and the view's own value wins"
  (let ([w (views:make (make-buffer "notes" "one\n"))])
    (check-equal? "view nowrap" (attribute (drawn w) "class"))
    (views:set-option! w views:wrap-lines #t)
    (check-equal? "view" (attribute (drawn w) "class"))))

(define (drawn-text v text spans)
  (car (test-user:elements (views-test/page:shown (haml (:span.drawn (views:draw-text v text spans)))) "drawn")))

(options:define-option shade "light" string?)

(test "draw-text draws text with span values by the rule a buffer's spans follow"
  (let ([v (views:make (make-buffer "plain" "x"))])
    (let ([e (drawn-text v "define x" '((0 6 ((face . keyword)))))])
      (check-equal? "define x" (test-user:element-text e))
      (check-equal? '(("keyword" "define")) (faces e)))
    (check-equal? '(("string" "define x") ("bold" "define") ("keyword" "define"))
      (faces (drawn-text v "define x" '((0 8 ((face . string))) (0 6 ((face keyword bold)))))))
    (check-equal? "a[b" (test-user:element-text (drawn-text v "ab" '((1 1 ((before . "[")))))))
    (check-equal? "a-c" (test-user:element-text (drawn-text v "abc" '((1 2 ((replace . "-")))))))
    (let ([e (drawn-text v "a\x7;b" '())])
      (check-equal? "a^Gb" (test-user:element-text e))
      (check-equal? '(("escape-glyph" "^G")) (faces e)))
    (check-raises (raised-with 'views:draw-text "not a list of spans in the text")
      (views:draw-text v "ab" '((0 3 ((face . keyword))))))
    (check-raises (raised-with 'views:draw-text "not a string") (views:draw-text v 'ab '()))))

(test "draw-text draws with the view's buffer and options current, so a buffer's local values decide how a value looks"
  (let* ([b (make-buffer "plain" "x")] [v (views:make b)])
    (tables:set! views:span-properties 'shade (lambda (v) (list (cons "data-shade" (shade)))))
    (buffers:with-buffer b (options:set-local! shade "dark"))
    (check-equal? '("dark") (map (lambda (e) (attribute e "data-shade"))
                                 (test-user:elements-with (drawn-text v "ab" '((0 1 ((shade . #t))))) "data-shade")))
    (tables:remove! views:span-properties 'shade)))
