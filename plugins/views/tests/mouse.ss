(import (tuna) (test) (views) (buffers) (document) (options) (tables) (commands) (keys) (web) (test-user)
        (views-test page) (views-test md))

(options:set! views:scroll-margin 2 views:wrap-lines #f)

(define desktop (views-test/page:open 400))
(define c1 (views-test/page:client desktop))

(define (make-buffer name content) (buffers:make (buffers:free-name name) content))

(define seen '())

(define (note! entry) (set! seen (cons entry seen)))

(define (take!)
  (let ([s (reverse seen)]) (set! seen '()) s))

(define (point-of posn) (views:posn-point posn))

(define last-posn #f)

(commands:define-command (record [event (keys:command-event)])
  "Records the key and places of the event that ran it, and whether its view was current."
  (let ([key (keys:event-key event)] [start (keys:event-start event)])
    (set! last-posn start)
    (note! (append (list key (point-of start))
                   (if (equal? key "<drag-mouse-1>") (list (point-of (keys:event-end event))) '())
                   (list (eq? (views:current) (views:posn-view start)))))))

(for-each (lambda (k) (keys:bind! keys:global k record))
  '("<down-mouse-1>" "<mouse-1>" "<drag-mouse-1>" "<mouse-movement>" "<wheel-down>" "<mouse-3>"))

(define (item view fields)
  (append fields
          (remp (lambda (field) (assoc (car field) fields))
                `(("type" . "mouse") ("button" . 1) ("clicks" . 1) ("modifiers" . #())
                  ("view" . ,(views:id view)) ("version" . ,(buffers:version (views:buffer view)))
                  ("showing" . ,(views:shown-count view))))))

(define (mouse! view . fields)
  (web:post-input! c1 (item view fields))
  (test-user:settle))

(define (reports-during thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (thunk)
    (advice-remove! report keep)
    (map condition-message (reverse reported))))

(define stale '("Stale click: what was clicked is gone"))

(define b (make-buffer "plain" "one two\nthree\n"))
(define v (views:make b))

(test "a view's element names its buffer's version and how many buffers it has shown"
  (let ([e (views-test/page:view-element desktop v)])
    (check-equal? "0" (test-user:element-attribute e "data-version"))
    (check-equal? "0" (test-user:element-attribute e "data-showing"))))

(test "a mouse item's place, characters after a line's start, after a position or a token, is a position now, pressed in the view"
  (mouse! v '("action" . "click") '("line" . 2) '("count" . 2))
  (mouse! v '("action" . "down") '("at" . 1) '("count" . 3))
  (mouse! v '("action" . "click") '("token" . 9))
  (check-equal? '(("<mouse-1>" 11 #t) ("<down-mouse-1>" 4 #t) ("<mouse-1>" 9 #t)) (take!)))

(test "a place on an older screen follows the token after it through the edits since, and one whose token went is stale"
  (buffers:replace! b 1 1 "XX")
  (mouse! v '("version" . 0) '("action" . "click") '("line" . 2) '("count" . 2))
  (mouse! v '("version" . 0) '("action" . "click") '("at" . 1) '("count" . 0))
  (check-equal? '(("<mouse-1>" 13 #t) ("<mouse-1>" 3 #t)) (take!))
  (buffers:replace! b 7 10 "")
  (check-equal? stale (reports-during (lambda () (mouse! v '("version" . 0) '("action" . "click") '("at" . 1) '("count" . 5)))))
  (mouse! v '("version" . 1) '("action" . "click") '("line" . 1) '("count" . 4))
  (check-equal? '(("<mouse-1>" 4 #t)) (take!)))

(test "a line place on an older screen counts from that line's start then"
  (buffers:replace! b 1 1 "\n\n")
  (mouse! v '("version" . 2) '("action" . "click") '("line" . 2) '("count" . 1))
  (check-equal? '(("<mouse-1>" 11 #t)) (take!))
  (check-equal? "\n\nXXone \nthree\n" (document:text (buffers:document b))))

(test "a press is kept for its drag's start, followed to now, and a release outside the view or a press with no place names no position"
  (mouse! v '("action" . "down") '("at" . 3) '("count" . 0))
  (buffers:replace! b 1 1 "!")
  (mouse! v '("action" . "drag") '("at" . 4) '("count" . 4))
  (mouse! v '("action" . "down") '("at" . 3) '("count" . 0))
  (mouse! v '("action" . "drag"))
  (mouse! v '("action" . "down"))
  (check-equal? '(("<down-mouse-1>" 3 #t) ("<drag-mouse-1>" 4 8 #t) ("<down-mouse-1>" 3 #t) ("<drag-mouse-1>" 3 #f #t)
                  ("<down-mouse-1>" #f #t))
                (take!)))

(test "a stale press reports once, and its release runs nothing and reports nothing more"
  (buffers:replace! b 1 2 "")
  (check-equal? stale (reports-during (lambda () (mouse! v '("version" . 4) '("action" . "down") '("at" . 1) '("count" . 0)))))
  (check-equal? '() (reports-during (lambda () (mouse! v '("version" . 4) '("action" . "drag") '("at" . 2) '("count" . 0)))))
  (check-equal? stale (reports-during (lambda () (mouse! v '("version" . 4) '("action" . "down") '("at" . 1) '("count" . 0)))))
  (check-equal? '() (reports-during (lambda () (mouse! v '("version" . 4) '("action" . "click") '("at" . 1) '("count" . 0)))))
  (check-equal? '() (take!)))

(test "a release takes its press, so a drag with no press before it is stale"
  (mouse! v '("action" . "down") '("at" . 1) '("count" . 0))
  (mouse! v '("action" . "drag") '("at" . 1) '("count" . 2))
  (check-equal? stale (reports-during (lambda () (mouse! v '("action" . "drag") '("at" . 1) '("count" . 3)))))
  (check-equal? '(("<down-mouse-1>" 1 #t) ("<drag-mouse-1>" 1 3 #t)) (take!)))

(test "a view that has shown another buffer since, or a view that is gone, makes the click stale"
  (let ([other (make-buffer "other" "abc\n")] [before (views:shown-count v)])
    (views:set-buffer! v other)
    (check-equal? (+ before 1) (views:shown-count v))
    (mouse! v '("action" . "down") '("at" . 1) '("count" . 1))
    (check-equal? stale (reports-during (lambda () (mouse! v `("showing" . ,before) '("action" . "click") '("at" . 1) '("count" . 0)))))
    (check-equal? stale (reports-during (lambda () (mouse! v '("view" . 99999) '("action" . "click") '("at" . 1) '("count" . 0)))))
    (mouse! v '("action" . "click") '("at" . 1) '("count" . 2))
    (check-equal? '(("<down-mouse-1>" 2 #t) ("<mouse-1>" 3 #t)) (take!))
    (mouse! v '("action" . "down") '("at" . 1) '("count" . 1))
    (views:set-buffer! v b)
    (check-equal? stale (reports-during (lambda () (mouse! v '("action" . "drag") '("at" . 1) '("count" . 2)))))
    (check-equal? '(("<down-mouse-1>" 2 #t)) (take!))
    (views:set-buffer! v other)))

(test "a version past the buffer's, or a place outside the content at the version, is not a mouse item"
  (for-each
    (lambda (fields)
      (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
        (advice-add! report keep)
        (apply mouse! v '("action" . "click") fields)
        (advice-remove! report keep)
        (check-equal? '(views:mouse-item) (map condition-who reported))))
    '((("version" . 99) ("at" . 1) ("count" . 0))
      (("at" . 1) ("count" . 99))
      (("line" . 9) ("count" . 0))
      (("token" . -1))
      (("at" . 1) ("count" . "x"))
      (("showing" . "x") ("at" . 1) ("count" . 0)))))

(test "a move reports a number that the client's next screen of the view brings back, whatever becomes of the move"
  (let ([reported (lambda () (test-user:element-attribute (views-test/page:view-element desktop v) "data-reported"))])
    (mouse! v '("action" . "move") '("report" . 42) '("showing" . 0) '("token" . 2))
    (check-equal? '() (take!))
    (check-equal? "42" (reported))
    (mouse! v '("action" . "move") '("report" . 43) '("at" . 1) '("count" . 1))
    (check-equal? '(("<mouse-movement>" 2 #t)) (take!))
    (check-equal? "43" (reported))))

(tables:define-table link-keys)
(tables:define-table image-keys)
(tables:define-table own-keys)
(tables:define-table marked-keys)
(tables:define-table close-keys)
(tables:define-table tab-keys)

(define (noting name)
  (lambda () (note! (list name (point-of (keys:event-start (keys:command-event)))))))

(commands:define-command (on-link) "Records a click on a link." ((noting 'link)))
(commands:define-command (on-image) "Records a click on an image." ((noting 'image)))
(commands:define-command (on-own) "Records a click on a span with its own keymap." ((noting 'own)))
(commands:define-command (on-marked) "Records a click on a span of the marked layer." ((noting 'marked)))
(commands:define-command (on-close) "Records a click on a close button." ((noting 'close)))
(commands:define-command (on-tab) "Records a click on a tab." ((noting 'tab)))

(keys:bind! link-keys "<mouse-1>" on-link)
(keys:bind! image-keys "<mouse-1>" on-image)
(keys:bind! own-keys "<mouse-1>" on-own)
(keys:bind! marked-keys "<mouse-1>" on-marked)
(keys:bind! close-keys "<mouse-1>" on-close)
(keys:bind! tab-keys "<mouse-1>" on-tab)
(keys:bind! tab-keys "<mouse-2>" on-tab)

(buffers:define-kind clicky-link (inline) (keymap link-keys))
(buffers:define-kind clicky-image (content atom) (inline) (keymap image-keys))
(buffers:define-layer marked (keymap marked-keys))

(define d (make-buffer "doc" (views-test/md:doc '() (views-test/md:para '() "See " (clicky-link '() "here") " and " (clicky-image '()) ".\n"))))
(define w (views:make d))

(test "each drawn node's element names its range; a token place on a node's opening names a position inside it, on an atom the one before it"
  (check-equal? '(("1" "21") ("6" "12") ("17" "18"))
    (map (lambda (n) (list (test-user:element-attribute n "data-at") (test-user:element-attribute n "data-to")))
         (test-user:elements (views-test/page:view-element desktop w) "node")))
  (mouse! w '("action" . "click") '("token" . 6))
  (mouse! w '("action" . "click") '("at" . 7) '("count" . 2))
  (mouse! w '("action" . "click") '("token" . 17))
  (mouse! w '("action" . "click") '("at" . 12) '("count" . 2))
  (check-equal? '((link 7) (link 9) (image 17) ("<mouse-1>" 14 #t)) (take!)))

(test "keymaps finds the atom right after the cursor too"
  (views:set-point! w 17)
  (check-equal? image-keys (car (views:keymaps w))))

(test "a click on a span looks the key up in the span's own keymap before its layer type's"
  (buffers:add-span! (buffers:layer d marked) 2 4 (list (cons 'keymap own-keys)))
  (buffers:add-span! (buffers:layer d marked) 4 6 '((face . highlight)))
  (mouse! w '("action" . "click") '("at" . 2) '("count" . 1))
  (mouse! w '("action" . "click") '("at" . 2) '("count" . 3))
  (check-equal? '((own 3) (marked 5)) (take!)))

(define (posn-of-click . fields)
  (apply mouse! w fields)
  (take!)
  last-posn)

(test "a posn is read through views' accessors; one without a place sent with it has no pointer place or cell"
  (keys:bind! link-keys "<mouse-1>" record)
  (keys:bind! image-keys "<mouse-1>" record)
  (let ([posn (posn-of-click '("action" . "click") '("at" . 7) '("count" . 2))])
    (check-equal? (list w 9 #f '(#f #f) '(#f #f))
      (list (views:posn-view posn) (views:posn-point posn) (views:posn-node posn)
            (call-with-values (lambda () (views:posn-x-y posn)) list) (call-with-values (lambda () (views:posn-cell posn)) list))))
  (check-raises (lambda (e) (equal? "not a position of a mouse key" (condition-message e))) (views:posn-point '#(2 1)))
  (check-raises (lambda (e) (equal? 'views:posn-view (condition-who e))) (views:posn-view '(2 1)))
  (check-raises (lambda (e) (equal? 'views:posn-cell (condition-who e))) (views:posn-cell 'here))
  (check-raises (lambda (e) (equal? "not a view" (condition-message e))) (views:shown-count 'v)))

(test "a place that names a token names the node the element stands for: the link, whose position is inside it, and the image atom"
  (check-equal? (list (buffers:kind-name (buffers:constructor-kind clicky-link))
                      (buffers:kind-name (buffers:constructor-kind clicky-image))
                      #f)
    (map (lambda (fields)
           (let ([n (views:posn-node (apply posn-of-click '("action" . "click") fields))])
             (and n (document:node-kind n))))
         '((("token" . 6)) (("token" . 17)) (("at" . 7) ("count" . 0))))))

(test "the pointer's place is in px from what was clicked, and its cell counts in the cells the page last reported"
  (let ([before (posn-of-click '("action" . "click") '("at" . 1) '("count" . 0) '("x" . 35.5) '("y" . 12))])
    (views-test/page:report! desktop w 1 0 #t)
    (let ([after (posn-of-click '("action" . "click") '("at" . 1) '("count" . 0) '("x" . 35.5) '("y" . 42)
                                '("column" . 3) '("row" . 2) '("keymaps" . #(99)))])
      (check-equal? '((35.5 12) (#f #f) (35.5 42) (3 2))
        (list (call-with-values (lambda () (views:posn-x-y before)) list)
              (call-with-values (lambda () (views:posn-cell before)) list)
              (call-with-values (lambda () (views:posn-x-y after)) list)
              (call-with-values (lambda () (views:posn-cell after)) list))))))

(define (mark-number keymap) (read (open-input-string (views:keymap-mark keymap))))

(test "a keymap mark names its keymap by a lasting number, followed by its state"
  (let ([close-mark (mark-number close-keys)])
    (check (fixnum? close-mark))
    (check-equal? close-mark (mark-number close-keys))
    (check (not (eqv? close-mark (mark-number link-keys))))
    (check-equal? (format "~a clickable" close-mark) (views:keymap-mark close-keys))
    (check-raises (lambda (e) (equal? "not a keymap" (condition-message e))) (views:keymap-mark 'close-keys))))

(test "a click in a marked element looks the key up there first, then in the marked keymaps around it, innermost first, then at the position"
  (let ([close-mark (mark-number close-keys)] [tab-mark (mark-number tab-keys)])
    (mouse! w '("action" . "down") '("token" . 6) `("keymaps" . ,(vector close-mark)))
    (mouse! w '("action" . "click") '("token" . 6) `("keymaps" . ,(vector close-mark)))
    (mouse! w '("action" . "click") '("token" . 6))
    (check-equal? '(("<down-mouse-1>" 7 #t) (close 7) ("<mouse-1>" 7 #t)) (take!))
    (mouse! w '("action" . "click") '("token" . 6) `("keymaps" . ,(vector close-mark tab-mark)))
    (mouse! w '("action" . "click") '("button" . 2) '("token" . 6) `("keymaps" . ,(vector close-mark tab-mark)))
    (mouse! w '("action" . "click") '("token" . 6) `("keymaps" . ,(vector tab-mark close-mark)))
    (mouse! w '("action" . "down") '("token" . 6) `("keymaps" . ,(vector close-mark tab-mark)))
    (check-equal? '((close 7) (tab 7) (tab 7) ("<down-mouse-1>" 7 #t)) (take!))
    (mouse! w '("action" . "click") '("token" . 6) '("keymaps" . #(12345)))
    (check-equal? '(("<mouse-1>" 7 #t)) (take!))))

(test "a wheel item is a wheel key at its place, and every button is sent, a release taking its press's button"
  (mouse! v '("action" . "wheel") '("direction" . "down") '("at" . 1) '("count" . 2))
  (mouse! v '("action" . "down") '("button" . 3) '("at" . 1) '("count" . 1))
  (mouse! v '("action" . "click") '("button" . 3) '("at" . 1) '("count" . 1))
  (check-equal? '(("<wheel-down>" 3 #t) ("<mouse-3>" 2 #t)) (take!)))
