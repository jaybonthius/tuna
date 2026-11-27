(import (tuna) (test) (test-user) (test-runner) (options) (hooks) (tables) (faces) (buffers) (document) (views) (layout) (web)
        (jump-history) (completion) (completion-list) (line-picker)
        (completion-test sessions) (completion-test picking) (buffers-test cards) (line-picker-test para))

(define (lines-text from to) (apply string-append (map (lambda (i) (format "line ~a\n" (+ from i))) (iota (- to from)))))

(define src #f)

(define (show! text)
  (test-user:show! text)
  (set! src (layout:selected-view)))

(define (buffer) (views:buffer src))

(define (line-start n) (document:line-start (buffers:document (buffer)) n))

(define (line-of p) (document:line (buffers:document (buffer)) p))

(define (session) (completion-test/picking:session))

(define (choices) (completion-test/picking:choices))

(define (quit!) (check-equal? '(cancelled) (completion-test/picking:quit!)))

(define (src-element)
  (let ([id (number->string (views:id src))])
    (find (lambda (e) (equal? id (test-user:element-attribute e "data-view")))
          (test-user:elements-with (test-user:screen) "data-view"))))

(define (drawn-faces face)
  (filter (lambda (e) (equal? face (test-user:element-attribute e "data-face")))
          (test-user:elements-with (src-element) "data-face")))

(test "M-s l reads a line of the buffer, split in a job; the selected line is previewed, and a quit brings point back"
  (show! (string-append "|" (lines-text 0 2000)))
  (test-user:press! "M-s l")
  (check-equal? 2000 (length (choices)))
  (test-user:type! "1999")
  (check-equal? '("line 1999") (choices))
  (test-user:settle)
  (check-equal? 2000 (line-of (views:point src)))
  (quit!)
  (check-equal? 1 (views:point src))
  (test-user:press! "M-s l")
  (test-user:type! "line 1500")
  (choices)
  (test-user:press! "RET")
  (check-equal? 1501 (line-of (views:point src))))

(define gamma-lines
  (apply string-append (map (lambda (i) (if (memv i '(3 7)) "   \n" (format "line ~a gamma\n" i))) (iota 12))))

(test "the lines come from point's line to the last, then from the first, leaving out lines of white space, so the read opens on point's line"
  (show! (string-append "|" gamma-lines))
  (views:set-point! src (+ (line-start 9) 2))
  (test-user:press! "M-s l")
  (check-equal? '("line 8 gamma" "line 9 gamma" "line 10 gamma" "line 11 gamma" "line 0 gamma" "line 1 gamma" "line 2 gamma"
                  "line 4 gamma" "line 5 gamma" "line 6 gamma")
                (choices))
  (check-equal? "line 8 gamma" (completion-test/picking:selected))
  (quit!))

(test "each row's prefix is its line number, padded to the last line's digits, in the warning face before point's line"
  (show! (string-append "|" gamma-lines))
  (views:set-point! src (+ (line-start 9) 2))
  (test-user:press! "M-s l")
  (choices)
  (let ([s (session)])
    (check-equal? (list (cons faces:shadow " 9") (cons faces:shadow "10") (cons faces:shadow "11") (cons faces:shadow "12")
                        (cons faces:warning " 1") (cons faces:warning " 2"))
                  (map (lambda (m) (completion:row-prefix s m)) (list-head (completion-test/sessions:matches s) 6))))
  (quit!))

(test "C-u lists from the first line, as line-picker:start-from-top? does, which C-u then turns round"
  (show! (string-append "|" gamma-lines))
  (views:set-point! src (+ (line-start 9) 2))
  (let ([first-line (lambda (keys) (test-user:press! keys) (let ([found (car (choices))]) (quit!) found))])
    (check-equal? "line 0 gamma" (first-line "C-u M-s l"))
    (options:set! line-picker:start-from-top? #t)
    (check-equal? "line 0 gamma" (first-line "M-s l"))
    (check-equal? "line 8 gamma" (first-line "C-u M-s l"))
    (options:unset! line-picker:start-from-top?)))

(buffers:define-layer colours)

(test "a row is drawn with its line's spans in the buffer's layers beside the matches; an edit elsewhere keeps them, an edit in the line drops them"
  (show! (string-append "|" gamma-lines))
  (views:set-point! src (line-start 9))
  (buffers:add-span! (buffers:layer (buffer) colours) (line-start 6) (+ (line-start 6) 4) (list (cons 'face faces:keyword)))
  (test-user:press! "M-s l")
  (test-user:type! "5 gam")
  (check-equal? '("line 5 gamma") (choices))
  (let* ([s (session)] [m (car (completion-test/sessions:matches s))])
    (check-equal? (list (list 0 4 (list (cons 'face faces:keyword)))) (completion:row-faces s m))
    (let ([text (car (test-user:elements (test-user:screen) "completion-text"))])
      (check-equal? (list "line" (symbol->string faces:keyword))
                    (let ([e (car (test-user:elements-with text "data-face"))])
                      (list (test-user:element-text e) (test-user:element-attribute e "data-face")))))
    (check-equal? (list " 6" (symbol->string faces:warning))
                  (let ([e (car (test-user:elements (test-user:screen) "completion-prefix"))])
                    (list (test-user:element-text e) (test-user:element-attribute e "data-face"))))
    (buffers:replace! (buffer) 1 1 "new\n")
    (check-equal? (list (list 0 4 (list (cons 'face faces:keyword)))) (completion:row-faces s m))
    (buffers:replace! (buffer) (+ (line-start 7) 1) (+ (line-start 7) 1) "x")
    (check-equal? '() (completion:row-faces s m)))
  (quit!))

(test "the read answers the leftmost match on the line chosen, whichever word it matches, which the preview shows with the line and its matches highlighted; the jump records the place left, so M-, returns"
  (options:set! completion:styles (list completion:any-order))
  (show! (string-append "|" gamma-lines))
  (views:set-point! src (line-start 9))
  (let ([jumps '()])
    (define (note v) (set! jumps (cons (views:point v) jumps)))
    (hooks:add! jump-history:after-jump note)
    (test-user:press! "M-s l")
    (test-user:type! "gam 2")
    (check-equal? '("line 2 gamma") (choices))
    (test-user:settle)
    (check-equal? (+ (line-start 3) 5) (views:point src))
    (check (pair? (drawn-faces "highlight")))
    (check-equal? '("2" "gam") (map test-user:element-text (drawn-faces "match")))
    (test-user:press! "RET")
    (check-equal? (+ (line-start 3) 5) (views:point src))
    (check-equal? '() (drawn-faces "highlight"))
    (check-equal? (list (+ (line-start 3) 5) (+ (line-start 3) 5)) (list-head jumps 2))
    (hooks:remove! jump-history:after-jump note))
  (test-user:press! "M-,")
  (check-equal? (line-start 9) (views:point src))
  (options:unset! completion:styles))

(test "the preview follows the input while the selection stays on a line, and a quit takes the preview and its highlight away"
  (options:set! completion:styles (list completion:any-order))
  (show! (string-append "|" gamma-lines))
  (views:set-point! src (line-start 9))
  (test-user:press! "M-s l")
  (choices)
  (test-user:type! "a")
  (choices)
  (test-user:settle)
  (check-equal? (list "line 8 gamma" 8) (list (completion-test/picking:selected) (- (views:point src) (line-start 9))))
  (test-user:type! " l")
  (choices)
  (test-user:settle)
  (check-equal? (list "line 8 gamma" 0) (list (completion-test/picking:selected) (- (views:point src) (line-start 9))))
  (quit!)
  (check-equal? (list (line-start 9) '()) (list (views:point src) (drawn-faces "highlight")))
  (options:unset! completion:styles))

(test "with nothing typed the read answers the line's start"
  (show! (string-append "|" gamma-lines))
  (views:set-point! src (line-start 9))
  (test-user:press! "M-s l")
  (choices)
  (test-user:press! "C-n RET")
  (check-equal? (line-start 10) (views:point src)))

(test "the lines are those of the buffer's text: an atom gives its kind's text, a line starting inside it is at the position before it, and the read lands at the leftmost match before an atom, or at the line's start"
  (show! "|")
  (views:set-buffer! src
    (buffers:make "rows" (buffers-test/cards:rows '() (line-picker-test/para:para '() "intro " (buffers-test/cards:tag '((label . "TAG"))) "\n")
                                         (buffers-test/cards:row '((label . "alpha"))) (buffers-test/cards:row '((label . "beta")))
                                         (line-picker-test/para:para '() "end\n"))))
  (test-user:press! "M-s l")
  (choices)
  (let ([s (session)])
    (check-equal? '(("intro TAG" . 0) ("alpha" . 11) ("beta" . 12) ("end" . 13))
                  (map (lambda (m) (cons (completion:text s m) (completion:value s m))) (completion-test/sessions:matches s))))
  (test-user:type! "beta")
  (choices)
  (test-user:press! "RET")
  (check-equal? 12 (views:point src))
  (for-each
    (lambda (typed at)
      (test-user:press! "M-s l")
      (test-user:type! typed)
      (choices)
      (test-user:press! "RET")
      (check-equal? at (views:point src)))
    '("tro" "TAG")
    '(4 2)))

(test "a large buffer's lines and its atoms' texts go to the job together"
  (show! "|")
  (views:set-buffer! src
    (buffers:make "many" (apply buffers-test/cards:rows '() (line-picker-test/para:para '() (lines-text 0 1100))
                                (map (lambda (i) (buffers-test/cards:row (list (cons 'label (format "row ~a" i))))) (iota 3)))))
  (test-user:press! "M-s l")
  (check-equal? 1103 (length (choices)))
  (test-user:type! "row 2")
  (check-equal? '("row 2") (choices))
  (test-user:press! "RET")
  (check-equal? 9895 (views:point src)))

(test "lines match inside a line by default, and in any order with completion:any-order"
  (check (equal? (list completion:substring) (tables:ref completion:category-default-styles line-picker:line-category #f)))
  (show! "|(define (f x)\n  (display x))\n")
  (test-user:press! "M-s l")
  (test-user:type! "display")
  (check-equal? '("  (display x))") (choices))
  (quit!)
  (show! "|alpha beta\nbeta gamma\ngamma alpha\n")
  (options:set! completion:styles (list completion:any-order))
  (for-each
    (lambda (typed found)
      (test-user:press! "M-s l")
      (test-user:type! typed)
      (check-equal? found (choices))
      (quit!))
    '("alpha gamma" "beta !gamma")
    '(("gamma alpha") ("alpha beta")))
  (options:unset! completion:styles))

(define %reports 0)

;; A scroll by hand is a page's report at rest of the line now at the
;; view's top; the first report on a new placement confirms it, so the
;; hand's is the second.
(define (scroll-by-hand! line)
  (let ([e (src-element)] [mark (lambda (k) (list (cons "line" (+ line k))))])
    (for-each
      (lambda (i)
        (set! %reports (+ %reports 1))
        (web:post-input! (test-user:client)
          `(("type" . "scroll") ("view" . ,(views:id src)) ("placement" . ,(string->number (test-user:element-attribute e "data-placement")))
            ("report" . ,%reports) ("version" . ,(buffers:version (buffer))) ("top" . ,(mark 0)) ("spacer" . #f) ("fraction" . 0)
            ("left" . null) ("past" . 0) ("sides" . #()) ("start" . ,(mark 2)) ("end" . ,(mark 7)) ("atStart" . #f) ("atEnd" . #f)
            ("columns" . 80) ("rows" . 10) ("pointVisible" . #t)
            ("wanted" . (("aboveLines" . 41) ("aboveChars" . 3280) ("belowLines" . 41) ("belowChars" . 3280) ("side" . 160)))
            ("settled" . #t) ("hand" . #t) ("edge" . "top"))))
      '(1 2))))

(test "while a long buffer's lines fill the list, the selected line is previewed once, and a hand scroll of its view stays"
  (show! (string-append "|" (apply string-append (map (lambda (i) (format "row ~a\n" i)) (iota 60000)))))
  (views:set-point! src (line-start 30000))
  (let* ([jumps 0] [note (lambda (v) (set! jumps (+ jumps 1)))])
    (hooks:add! jump-history:after-jump note)
    (test-user:press! "M-s l")
    (test-runner:wait-until (lambda () (> jumps 0)))
    (test-user:settle)
    (scroll-by-hand! 100)
    (let ([scrolled-at (completion:matches-count (completion:session-matches (session)))])
      (check-equal? 60000 (length (choices)))
      (test-user:settle)
      (check-equal? (list #t "row 29999" 1 100)
                    (list (< scrolled-at 60000) (completion-test/picking:selected) jumps (line-of (views:top src #f)))))
    (hooks:remove! jump-history:after-jump note)
    (quit!)))
