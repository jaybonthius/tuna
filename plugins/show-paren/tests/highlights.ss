(import (tuna) (test) (test-user) (options) (buffers) (document) (views) (modes) (layout) (layout-split) (show-paren)
        (editing-test scene) (sexp-test scene))

(define show! sexp-test/scene:show!)

(define highlighted
  (case-lambda
    [() (highlighted (editing-test/scene:view))]
    [(view)
     (test-user:settle)
     (let* ([b (views:buffer view)] [doc (buffers:document b)])
       (map (lambda (s) (list (buffers:text-between doc (car s) (cadr s)) (cdr (assq 'face (caddr s)))))
            (buffers:spans (buffers:layer b show-paren:highlights view) 0 (document:length doc))))]))

(test "a closing bracket before the cursor is highlighted with its opening bracket"
  (show! "(a b)|")
  (check-equal? '(("(" show-paren.match) (")" show-paren.match)) (highlighted)))

(test "an opening bracket after the cursor is highlighted with its closing bracket"
  (show! "|(a b)")
  (check-equal? '(("(" show-paren.match) (")" show-paren.match)) (highlighted)))

(test "between a closing and an opening bracket, the closing one before the cursor wins"
  (let ([b (show! "(a)|(b)")])
    (check-equal? '((1 2) (3 4))
                  (map (lambda (s) (list (car s) (cadr s)))
                       (buffers:spans (buffers:layer b show-paren:highlights (editing-test/scene:view)) 0 8)))))

(test "brackets right inside the cursor are not highlighted by default"
  (show! "(|a b)")
  (check-equal? '() (highlighted))
  (show! "(a b|)")
  (check-equal? '() (highlighted)))

(test "with when-point-inside-paren, the opening bracket before the cursor and the closing one after are highlighted"
  (options:set! show-paren:when-point-inside-paren #t)
  (show! "(|a b)")
  (check-equal? '(("(" show-paren.match) (")" show-paren.match)) (highlighted))
  (show! "(a b|)")
  (check-equal? '(("(" show-paren.match) (")" show-paren.match)) (highlighted))
  (options:unset! show-paren:when-point-inside-paren))

(test "with when-point-in-periphery, a cursor in a line's blanks highlights the bracket at that end of its text"
  (options:set! show-paren:when-point-in-periphery #t)
  (show! "  |(a b)")
  (check-equal? '(("(" show-paren.match) (")" show-paren.match)) (highlighted))
  (show! "(a b)   |")
  (check-equal? '(("(" show-paren.match) (")" show-paren.match)) (highlighted))
  (options:unset! show-paren:when-point-in-periphery))

(test "a pair whose closing bracket has another shape is a mismatch"
  (show! "(a b]|")
  (check-equal? '(("(" show-paren.mismatch) ("]" show-paren.mismatch)) (highlighted)))

(test "a bracket with no match is a mismatch alone"
  (show! "a b)|")
  (check-equal? '((")" show-paren.mismatch)) (highlighted))
  (show! "|(a b")
  (check-equal? '(("(" show-paren.mismatch)) (highlighted)))

(test "brackets in strings and comments, and a character literal, are not brackets"
  (show! "(\"a (b\" c)|")
  (check-equal? '(("(" show-paren.match) (")" show-paren.match)) (highlighted))
  (show! "; (a)|")
  (check-equal? '() (highlighted))
  (show! "#\\)|")
  (check-equal? '() (highlighted)))

(test "each cursor highlights its own brackets"
  (show! "(a)| [b]|")
  (check-equal? '(("(" show-paren.match) (")" show-paren.match) ("[" show-paren.match) ("]" show-paren.match))
                (highlighted)))

(test "each view of a buffer shows the matches of its own cursors"
  (let* ([b (show! "(a) |[b]")] [top (editing-test/scene:view)]
         [bottom (layout-split:display-below (buffers:make (buffers:free-name "other") ""))])
    (views:set-buffer! bottom b)
    (views:set-point! bottom 4)
    (check-equal? '(("[" show-paren.match) ("]" show-paren.match)) (highlighted top))
    (check-equal? '(("(" show-paren.match) (")" show-paren.match)) (highlighted bottom))
    (layout:delete-part! (layout:view-node bottom))))

(test "with the mode off, or in a buffer with no lexer, nothing is highlighted"
  (let ([b (show! "(a b)|")])
    (buffers:with-buffer b (options:set-local! show-paren:mode #f))
    (check-equal? '() (highlighted)))
  (sexp-test/scene:show-in! modes:fundamental "(a b)|")
  (check-equal? '() (highlighted)))

(test "a view that turns to another buffer loses the old buffer's highlights"
  (let ([b (show! "(a b)|")])
    (check-equal? 2 (length (highlighted)))
    (show! "x|")
    (test-user:settle)
    (check-equal? '() (buffers:spans (buffers:layer b show-paren:highlights (editing-test/scene:view)) 0 7))))

(test "a bracket at the start of a line inside a multi-line string is highlighted with its match, with nothing raised"
  (show! "(define (f)\n  \"Use it as\n|(f 1)\n  then\")")
  (check-equal? '() (editing-test/scene:reports-during test-user:settle))
  (check-equal? '(("(" show-paren.match) (")" show-paren.match)) (highlighted)))
