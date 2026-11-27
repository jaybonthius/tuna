(import (tuna) (test) (test-user) (commands) (views) (kill-ring) (editing) (scene) (md))

(define (notes)
  (md:doc '() (md:heading '() "Head\n") (md:para '() "First para.\n") (md:para '() "Second para.\n") (md:para '() "Last.\n")))

(define (plan) (md:doc '() (md:heading '() "Plan\n") (md:para '() "Buy milk.\n")))

(define (sheet)
  (md:doc '() (md:para '() "Hi\n") (md:grid '() (md:row '() (md:cell '() "a\n") (md:cell '() "b\n"))) (md:para '() "Yo\n")))

(test "word and case commands in nodes: an atom ends a word, and a kill of a line's text leaves its block"
  (scene:show! (md:doc '() (md:para '() "one two\n") (md:para '() "three\n") (md:para '() "four " (md:image '((src . "x"))) "five\n"))
               2)
  (test-user:press! "M-u M-u M-u M-u")
  (check-equal? (list "ONE TWO\nTHREE\nFOUR \xFFFC;five\n" '((24 #f))) (scene:state))
  (test-user:press! "C-a C-k")
  (check-equal? '(md:doc () (md:para () "ONE TWO\n") (md:para () "THREE\n") (md:para () "\n")) (scene:root)))

(test "a kill at a block's end joins the next block's text; whole lines take whole blocks, which a yank puts back"
  (scene:show! (notes) 20)
  (test-user:press! "C-k")
  (check-equal? '(((md:heading () "Head\n") (md:para () "First para.Second para.\n") (md:para () "Last.\n")) ((20 #f)))
    (list (scene:blocks) (scene:cursors)))
  (scene:show! (notes) 3)
  (test-user:press! "C-u 1 C-k")
  (check-equal? '(((md:heading () "HFirst para.\n") (md:para () "Second para.\n") (md:para () "Last.\n")) ("ead\n"))
    (list (scene:blocks) (scene:kills 1)))
  (scene:show! (notes) 2)
  (test-user:press! "C-S-DEL")
  (check-equal? '(((md:para () "First para.\n") (md:para () "Second para.\n") (md:para () "Last.\n")) ((2 #f)) ("Head\n"))
    (list (scene:blocks) (scene:cursors) (scene:kills 1)))
  (test-user:press! "C-y")
  (check-equal? '(((md:heading () "Head\n") (md:para () "First para.\n") (md:para () "Second para.\n") (md:para () "Last.\n")) ((9 #f)))
    (list (scene:blocks) (scene:cursors))))

(test "the buffer ends before its last block's line break: a kill there removes nothing and adds no entry, and the last block keeps its break"
  (scene:show! (notes) 2)
  (kill-ring:push! (list "newest"))
  (test-user:press! "M-> M-d")
  (check-equal? (list (cddr (notes)) '((43 #f)) '("newest")) (list (scene:blocks) (scene:cursors) (scene:kills 1)))
  (check-equal? '((editing:kill-line "end of buffer")) (scene:press-reports! "C-k"))
  (test-user:press! "C-S-DEL")
  (check-equal? '(((md:heading () "Head\n") (md:para () "First para.\n") (md:para () "Second para.\n") (md:para () "\n")) ((38 #f)))
    (list (scene:blocks) (scene:cursors))))

(test "the content starts at the first stop, so kills on the first line keep the first block's opening"
  (scene:show! (notes) 4)
  (test-user:press! "C-u 0 C-k")
  (check-equal? '((md:heading () "ad\n") ("He")) (list (car (scene:blocks)) (scene:kills 1)))
  (test-user:press! "C-u 0 C-S-DEL")
  (check-equal? '(md:heading () "\n") (car (scene:blocks))))

(test "C-d and DEL remove an empty block whole"
  (scene:show! (md:doc '() (md:para '() "a\n") (md:para '() "\n") (md:para '() "b\n")) 6)
  (test-user:press! "C-d")
  (check-equal? '(((md:para () "a\n") (md:para () "b\n")) ((6 #f))) (list (scene:blocks) (scene:cursors)))
  (scene:show! (md:doc '() (md:para '() "a\n") (md:para '() "\n") (md:para '() "b\n")) 6)
  (test-user:press! "DEL")
  (check-equal? '(((md:para () "a\n") (md:para () "b\n")) ((3 #f))) (list (scene:blocks) (scene:cursors))))

(test "C-d and C-k before an atom standing as a block remove it, the cursor staying; DEL after it removes it too"
  (let ([ruled (lambda () (md:doc '() (md:para '() "ab\n") (md:rule '()) (md:para '() "cd\n")))])
    (for-each
      (lambda (point keys cursor)
        (scene:show! (ruled) point)
        (test-user:press! keys)
        (check-equal? (list '((md:para () "ab\n") (md:para () "cd\n")) (list (list cursor #f)))
          (list (scene:blocks) (scene:cursors))))
      '(4 4 8)
      '("C-d" "C-k" "DEL")
      '(4 4 7))))

(test "typing, C-y and DEL then typing over a selected heading give one result, where the deletion leaves the cursor"
  (scene:with-setting editing:delete-selection #t
    (lambda ()
      (for-each
        (lambda (keys)
          (scene:show! (plan) 9)
          (views:set-mark! (scene:view) 2)
          (kill-ring:push! (list "x"))
          (test-user:press! keys)
          (check-equal? '(((md:para () "xBuy milk.\n")) ((3 #f))) (list (scene:blocks) (scene:cursors))))
        '("x" "C-y" "DEL x")))))

(test "M-w, C-w and the primary selection of a heading's line take one kill, the heading whole, which C-y puts back as a heading"
  (scene:show! (plan) 9)
  (views:set-mark! (scene:view) 2)
  (test-user:press! "C-f C-b")
  (let ([primary (kill-ring:text (list (editing:primary-selection)))])
    (test-user:press! "M-w")
    (let ([copied (scene:kills 1)])
      (views:set-mark! (scene:view) 2)
      (test-user:press! "C-w")
      (check-equal? '("Plan\n" ("Plan\n") ("Plan\n") ((md:para () "Buy milk.\n")))
        (list primary copied (scene:kills 1) (scene:blocks)))))
  (test-user:press! "C-y")
  (check-equal? '((md:heading () "Plan\n") (md:para () "Buy milk.\n")) (scene:blocks)))

(test "two cursors kill whole blocks"
  (scene:show! (md:doc '() (md:para '() "a\n") (md:para '() "b\n") (md:para '() "c\n") (md:para '() "d\n")) 2 10)
  (test-user:press! "C-S-DEL")
  (check-equal? '(((md:para () "b\n") (md:para () "d\n")) ((2 #f) (6 #f)) ("a\n\nc\n"))
    (list (scene:blocks) (scene:cursors) (scene:kills 1))))

(test "case commands give each block its line break back"
  (scene:show! (md:doc '() (md:para '() "one\n") (md:para '() "two\n")) 2)
  (test-user:press! "M-2 M-u")
  (check-equal? '(((md:para () "ONE\n") (md:para () "TWO\n")) ((11 #f))) (list (scene:blocks) (scene:cursors))))

(test "lines in different blocks move and sort as texts: each block keeps its kind"
  (scene:show! (md:doc '() (md:heading '() "b\n") (md:para '() "a\n")) 2)
  (test-user:press! "M-<down>")
  (check-equal? '(((md:heading () "a\n") (md:para () "b\n")) ((6 #f))) (list (scene:blocks) (scene:cursors)))
  (test-user:press! "M-<up>")
  (check-equal? '(((md:heading () "b\n") (md:para () "a\n")) ((2 #f))) (list (scene:blocks) (scene:cursors)))
  (views:set-mark! (scene:view) 7)
  (scene:run editing:sort-lines)
  (check-equal? '(((md:heading () "a\n") (md:para () "b\n")) ((2 #f))) (list (scene:blocks) (scene:cursors))))

(test "a deleting cursor goes to the stop of the earlier of the start asked and the start the deletion fitted"
  (scene:show! (sheet) 20)
  (views:set-mark! (scene:view) 10)
  (test-user:press! "C-w")
  (check-equal? '(((md:para () "Hi\n") (md:grid () (md:row () (md:cell () "a\n") (md:cell () "\n"))) (md:para () "o\n")) ((10 #f)))
    (list (scene:blocks) (scene:cursors))))

(test "word motion stops at an isolating node's edge without a word"
  (scene:show! (sheet) 9)
  (test-user:press! "M-f")
  (check-equal? '((10 #f)) (scene:cursors))
  (check-equal? '() (scene:press-reports! "M-f"))
  (check-equal? '((10 #f)) (scene:cursors)))

(test "kill-line inside an isolating node ends at its edge with any count, and the buffer keeps the node's line break"
  (for-each
    (lambda (keys)
      (scene:show! (md:doc '() (md:para '() "Hi\n") (md:grid '() (md:row '() (md:cell '() "ab\n") (md:cell '() "b\n")))) 10)
      (test-user:press! keys)
      (check-equal? '(((md:para () "Hi\n") (md:grid () (md:row () (md:cell () "a\n") (md:cell () "b\n")))) ("b"))
        (list (scene:blocks) (scene:kills 1))))
    '("C-k" "C-u C-k")))

(test "with backward-kill-word-stops-at-whitespace?, M-DEL's run of whitespace passes a block's end, and the deletion joins the blocks as DEL does"
  (scene:with-setting editing:backward-kill-word-stops-at-whitespace? #t
    (lambda ()
      (scene:show! (md:doc '() (md:para '() "one \n") (md:para '() "  two\n")) 11)
      (test-user:press! "M-DEL")
      (check-equal? '(((md:para () "onetwo\n")) ((5 #f))) (list (scene:blocks) (scene:cursors)))
      (test-user:press! "M-DEL")
      (check-equal? '(((md:para () "two\n")) ((2 #f)) ("one")) (list (scene:blocks) (scene:cursors) (scene:kills 1))))))
