(import (tuna) (test) (test-user) (test-runner) (options) (hooks) (tables) (modes) (buffers) (document) (views) (web) (ui)
        (minibuffer) (completion) (completion rows) (completion-list) (completion-popup) (editing) (sessions))

(define (contains? text piece)
  (let loop ([i 0])
    (and (<= (+ i (string-length piece)) (string-length text))
         (or (string=? (substring text i (+ i (string-length piece))) piece) (loop (+ i 1))))))

(define (quit! r)
  (test-user:press! "C-g")
  (check-raises cancelled? (sessions:result r)))

(define (rows-view)
  (let ([b (find (lambda (b) (contains? (buffers:name b) "*Completions")) (buffers:all))])
    (unless (and b (pair? (views:showing b)))
      (error 'rows-view "no view of a session's rows" (map buffers:name (buffers:all))))
    (car (views:showing b))))

(define (view-element v)
  (find (lambda (e) (equal? (number->string (views:id v)) (test-user:element-attribute e "data-view")))
        (test-user:elements-with (test-user:screen) "data-view")))

(define (rows-element) (car (test-user:elements (view-element (rows-view)) "completion-rows")))

(define (row-text row) (test-user:element-text (car (test-user:elements row "completion-text"))))

(define (drawn-rows) (map row-text (test-user:elements (view-element (rows-view)) "ui-list-row")))

(define (drawn-selected)
  (let ([current (filter (lambda (row) (equal? "true" (test-user:element-attribute row "aria-current")))
                         (test-user:elements (view-element (rows-view)) "ui-list-row"))])
    (and (pair? current) (row-text (car current)))))

(define (state) (list (sessions:selected-text (sessions:session)) (drawn-selected)))

(define (two-before sources)
  (lambda ()
    (let ([p (views:point (views:current))])
      (and (> p 2) (completion:region (- p 2) p sources)))))

(define ab-region
  (two-before (list (completion:source (candidates (list->vector (map (lambda (c) (string #\a #\b c)) (string->list "abcdefghijklmnop"))))))))

(test "every match of a popup is a row, and the row drawn selected is the session's selection after each move, none before"
  (hooks:add! completion:find-region ab-region)
  (test-user:show! "ab|")
  (test-user:press! "C-M-i")
  (check-equal? 16 (length (drawn-rows)))
  (check-equal? '(#f #f) (state))
  (for-each
    (lambda (key expected)
      (test-user:press! key)
      (check-equal? (list expected expected) (state)))
    '("<down>" "<down>" "<down>" "<up>" "C-n" "C-p" "<up>")
    '("aba" "abb" "abc" "abb" "abc" "abb" "aba"))
  (test-user:press! "C-g")
  (hooks:remove! completion:find-region ab-region))

(test "a read that preselects nothing draws no row selected until a move selects one"
  (options:set! completion:read-preselect 'none)
  (let ([r (sessions:start! (lambda () (completion:read "Word: " (list (completion:source (candidates (vector "alpha" "almond" "apple" "banana")))) #f)))])
    (check-equal? '(#f #f) (state))
    (check-equal? '("alpha" "apple" "almond" "banana") (drawn-rows))
    (test-user:press! "<down>")
    (check-equal? '("alpha" "alpha") (state))
    (test-user:press! "<down>")
    (check-equal? '("apple" "apple") (state))
    (test-user:press! "RET")
    (check-equal? "apple" (sessions:result r)))
  (options:unset! completion:read-preselect))

(test "a group's title is a heading above its first row, never inside a row, and every match is a row"
  (let ([r (sessions:start!
             (lambda ()
               (completion:read "? "
                 (list (completion:source
                         (candidates (list->vector (append (map (lambda (i) (format "a.txt:~a:x" (+ i 1))) (iota 30)) (list "b.txt:1:x"))))
                         (in-order)
                         (group (lambda (text value) (substring text 0 5)) (lambda (text value) (substring text 6 (string-length text))))))
                 #f)))])
    (let ([e (view-element (rows-view))])
      (check-equal? '("a.txt" "b.txt") (map test-user:element-text (test-user:elements e "ui-list-heading")))
      (check-equal? 31 (length (test-user:elements e "ui-list-row")))
      (check-equal? "1:x" (car (drawn-rows)))
      (check (for-all (lambda (row) (null? (test-user:elements row "ui-list-heading"))) (test-user:elements e "ui-list-row"))))
    (quit! r)))

(test "a match is drawn as a completion-match span in its face"
  (let ([r (sessions:start!
             (lambda ()
               (completion:read "? "
                 (list (completion:source (candidates (vector "file-picker:find-file" "files:save-buffer")) (styles (list completion:any-order))))
                 #f)))])
    (test-user:type! "file find")
    (let ([marks (test-user:elements (view-element (rows-view)) "completion-match")])
      (check-equal? '(("file" "completion.match-0") ("find" "completion.match-1"))
        (map (lambda (m) (list (test-user:element-text m) (test-user:element-attribute m "data-face"))) marks)))
    (quit! r)))

(completion:define-category sized-category "Words annotated with their length.")

(test "the rows' columns are as wide as the widest drawn in the session, written on the rows' element, and only grow"
  (tables:set! completion:annotators sized-category
    (lambda (session) (lambda (word details) (list (number->string (string-length word))))))
  (let ([r (sessions:start!
             (lambda ()
               (minibuffer:call-with-setup (lambda (p) (minibuffer:set-input! p "q"))
                 (lambda () (completion:read "Word: " (list (completion:source (candidates (vector "q" "abcdefghij")) (category sized-category))) #f)))))]
        [style (lambda () (test-user:element-attribute (rows-element) "style"))])
    (check-equal? "--completion-column-1-size:1ch;--completion-rows-width:3ch" (style))
    (check-equal? '("1") (map test-user:element-text (test-user:elements (rows-element) "completion-annotation")))
    (test-user:press! "DEL")
    (check-equal? "--completion-column-1-size:2ch;--completion-rows-width:13ch" (style))
    (test-user:type! "q")
    (check-equal? "--completion-column-1-size:2ch;--completion-rows-width:13ch" (style))
    (quit! r))
  (tables:remove! completion:annotators sized-category))

(define al-region (two-before (list (completion:source (candidates (vector "alpha" "almond"))))))

(test "the rows' buffer is in the display's own mode, derived from completion/rows:mode, and one display's hook changes it alone"
  (let ([margin (lambda () (options:set-local! views:scroll-margin 3))])
    (hooks:add! completion-popup:mode-hook margin)
    (let ([r (sessions:start! (lambda () (completion:read "Word: " (list (completion:source (candidates (vector "alpha" "apple")))) #f)))])
      (let ([b (views:buffer (rows-view))])
        (check-equal? (list completion-list:mode #t) (list (modes:major-mode b) (modes:derived? (modes:major-mode b) completion/rows:mode)))
        (check-equal? '(2 #f #f) (buffers:with-buffer b (list (views:scroll-margin) (views:cursor-visible) (views:hand-scroll-moves-point))))
        (check (buffers:internal-name? (buffers:name b))))
      (quit! r))
    (hooks:add! completion:find-region al-region)
    (test-user:show! "al|")
    (test-user:press! "C-M-i")
    (let ([b (views:buffer (rows-view))])
      (check-equal? (list completion-popup:mode '(3 #f #f))
        (list (modes:major-mode b) (buffers:with-buffer b (list (views:scroll-margin) (views:cursor-visible) (views:hand-scroll-moves-point))))))
    (test-user:press! "C-g")
    (hooks:remove! completion:find-region al-region)
    (hooks:remove! completion-popup:mode-hook margin)))

(define %reports 0)

(define (drawn-row-tokens)
  (map (lambda (node) (cons (string->number (test-user:element-attribute node "data-at")) (row-text (caddr node))))
       (filter (lambda (node)
                 (let ([first (and (pair? (cddr node)) (caddr node))])
                   (and (pair? first) (symbol? (car first)) (equal? "ui-list-row" (test-user:element-attribute first "class")))))
               (filter (lambda (node) (equal? "node whole" (test-user:element-attribute node "class")))
                       (test-user:elements (view-element (rows-view)) "node")))))

(define (row-tokens) (map car (drawn-row-tokens)))

;; The stream's items are numbered by their place in the list, so any
;; drawn row gives where the list starts.
(define (list-start)
  (let ([drawn (car (drawn-row-tokens))])
    (- (car drawn) 1 (string->number (substring (cdr drawn) 5 (string-length (cdr drawn)))))))

(define (placement) (test-user:element-attribute (view-element (rows-view)) "data-placement"))

(define (scroll-by-hand! row)
  (let ([v (rows-view)] [at (lambda (k) (list (cons "at" (+ (list-start) 1 k))))])
    (set! %reports (+ %reports 1))
    (web:post-input! (test-user:client)
      `(("type" . "scroll") ("view" . ,(views:id v)) ("placement" . ,(string->number (placement)))
        ("report" . ,%reports) ("version" . ,(buffers:version (views:buffer v)))
        ("top" . ,(at row)) ("spacer" . #f) ("fraction" . 0) ("left" . null) ("past" . 0) ("sides" . #())
        ("start" . ,(at row)) ("end" . ,(at (+ row 9))) ("atStart" . #f) ("atEnd" . #f)
        ("columns" . 40) ("rows" . 10) ("pointVisible" . #t)
        ("wanted" . (("aboveLines" . 41) ("aboveChars" . 1640) ("belowLines" . 41) ("belowChars" . 1640) ("side" . 80)))
        ("settled" . #t) ("hand" . #t) ("edge" . "top")))
    (test-user:settle)))

(define (row-at-top) (- (views:top (rows-view) (test-user:client)) (list-start) 1))

(define (click-row! token version)
  (let ([v (rows-view)])
    (for-each
      (lambda (action)
        (set! %reports (+ %reports 1))
        (web:post-input! (test-user:client)
          `(("type" . "mouse") ("action" . ,action) ("button" . 1) ("clicks" . 1) ("modifiers" . #())
            ("view" . ,(views:id v)) ("version" . ,version) ("showing" . ,(views:shown-count v)) ("report" . ,%reports)
            ("token" . ,token))))
      '("down" "click"))
    (test-user:settle)))

(define feed #f)

(define (stream-read)
  (completion:read "Item: " (list (completion:source (stream (lambda (emit) (set! feed emit) (lambda (prefix) (void)))) (in-order))) #f))

(define (lines from to) (list->vector (map (lambda (i) (format "item-~a" (+ from i))) (iota (- to from)))))

(define (rows-count) (completion:matches-count (completion:session-matches (sessions:session))))

(define (fed! from to)
  (feed (lines from to))
  (test-runner:wait-until (lambda () (= (rows-count) to)))
  (test-user:settle))

(define (place) (list (placement) (views:point (rows-view)) (row-at-top) (completion:session-matches (sessions:session))))

(test "a stream's rounds and its end add rows without moving a list scrolled by hand, and a click on a row drawn before chooses it"
  (let ([r (sessions:start! stream-read)])
    (for-each (lambda (k) (fed! (* k 1000) (* (+ k 1) 1000))) (iota 5))
    (scroll-by-hand! 2000)
    (check-equal? (list 2000 "item-0") (list (row-at-top) (sessions:selected-text (sessions:session))))
    (let ([before (place)] [version (buffers:version (views:buffer (rows-view)))]
          [token (car (find (lambda (drawn) (string=? "item-2005" (cdr drawn))) (drawn-row-tokens)))])
      (fed! 5000 5100)
      (feed 'done)
      (sessions:wait-matches (sessions:session))
      (test-user:settle)
      (check-equal? before (place))
      (check-equal? 5100 (rows-count))
      (click-row! token version)
      (check-equal? "item-2005" (sessions:result r)))))

(test "with nothing selected a stream's rounds leave the view where it is, and a command shows the selection again"
  (options:set! completion:read-preselect 'none)
  (let ([r (sessions:start! stream-read)])
    (fed! 0 3000)
    (scroll-by-hand! 1500)
    (let ([before (place)])
      (fed! 3000 3500)
      (feed 'done)
      (sessions:wait-matches (sessions:session))
      (test-user:settle)
      (check-equal? #f (completion:selected (sessions:session)))
      (check-equal? (list-head before 3) (list-head (place) 3)))
    (for-each
      (lambda (key expected)
        (test-user:press! key)
        (check-equal? (list expected #t) (list (sessions:selected-text (sessions:session)) (views:following? (rows-view)))))
      '("C-n" "M->" "M-<")
      '("item-0" "item-3499" "item-0"))
    (quit! r))
  (options:unset! completion:read-preselect))

(test "a stream that ends with few lines is matched on the main thread and keeps its matches and the view's place"
  (let ([r (sessions:start! stream-read)])
    (fed! 0 600)
    (fed! 600 900)
    (scroll-by-hand! 400)
    (let ([before (place)])
      (feed 'done)
      (sessions:wait-matches (sessions:session))
      (test-user:settle)
      (check-equal? before (place)))
    (quit! r)))

(test "a click on a row of a read's list chooses it"
  (let ([r (sessions:start! (lambda () (completion:read "Word: " (list (completion:source (candidates (vector "alpha" "almond" "apple" "banana")))) #f)))])
    (click-row! (list-ref (row-tokens) 2) (buffers:version (views:buffer (rows-view))))
    (check-equal? "almond" (sessions:result r))))
