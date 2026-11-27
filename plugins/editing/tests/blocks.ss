(import (tuna) (test) (test-user) (commands) (views) (kill-ring) (editing) (editing-test scene) (editing-test md))

(define (notes)
  (editing-test/md:doc '() (editing-test/md:heading '() "Head\n") (editing-test/md:para '() "First para.\n") (editing-test/md:para '() "Second para.\n") (editing-test/md:para '() "Last.\n")))

(define (plan) (editing-test/md:doc '() (editing-test/md:heading '() "Plan\n") (editing-test/md:para '() "Buy milk.\n")))

(define (sheet)
  (editing-test/md:doc '() (editing-test/md:para '() "Hi\n") (editing-test/md:grid '() (editing-test/md:row '() (editing-test/md:cell '() "a\n") (editing-test/md:cell '() "b\n"))) (editing-test/md:para '() "Yo\n")))

(test "word and case commands in nodes: an atom ends a word, and a kill of a line's text leaves its block"
  (editing-test/scene:show! (editing-test/md:doc '() (editing-test/md:para '() "one two\n") (editing-test/md:para '() "three\n") (editing-test/md:para '() "four " (editing-test/md:image '((src . "x"))) "five\n"))
               2)
  (test-user:press! "M-u M-u M-u M-u")
  (check-equal? (list "ONE TWO\nTHREE\nFOUR \xFFFC;five\n" '((24 #f))) (editing-test/scene:state))
  (test-user:press! "C-a C-k")
  (check-equal? '(editing-test/md:doc () (editing-test/md:para () "ONE TWO\n") (editing-test/md:para () "THREE\n") (editing-test/md:para () "\n")) (editing-test/scene:root)))

(test "a kill at a block's end joins the next block's text; whole lines take whole blocks, which a yank puts back"
  (editing-test/scene:show! (notes) 20)
  (test-user:press! "C-k")
  (check-equal? '(((editing-test/md:heading () "Head\n") (editing-test/md:para () "First para.Second para.\n") (editing-test/md:para () "Last.\n")) ((20 #f)))
    (list (editing-test/scene:blocks) (editing-test/scene:cursors)))
  (editing-test/scene:show! (notes) 3)
  (test-user:press! "C-u 1 C-k")
  (check-equal? '(((editing-test/md:heading () "HFirst para.\n") (editing-test/md:para () "Second para.\n") (editing-test/md:para () "Last.\n")) ("ead\n"))
    (list (editing-test/scene:blocks) (editing-test/scene:kills 1)))
  (editing-test/scene:show! (notes) 2)
  (test-user:press! "C-S-DEL")
  (check-equal? '(((editing-test/md:para () "First para.\n") (editing-test/md:para () "Second para.\n") (editing-test/md:para () "Last.\n")) ((2 #f)) ("Head\n"))
    (list (editing-test/scene:blocks) (editing-test/scene:cursors) (editing-test/scene:kills 1)))
  (test-user:press! "C-y")
  (check-equal? '(((editing-test/md:heading () "Head\n") (editing-test/md:para () "First para.\n") (editing-test/md:para () "Second para.\n") (editing-test/md:para () "Last.\n")) ((9 #f)))
    (list (editing-test/scene:blocks) (editing-test/scene:cursors))))

(test "the buffer ends before its last block's line break: a kill there removes nothing and adds no entry, and the last block keeps its break"
  (editing-test/scene:show! (notes) 2)
  (kill-ring:push! (list "newest"))
  (test-user:press! "M-> M-d")
  (check-equal? (list (cddr (notes)) '((43 #f)) '("newest")) (list (editing-test/scene:blocks) (editing-test/scene:cursors) (editing-test/scene:kills 1)))
  (check-equal? '((editing:kill-line "end of buffer")) (editing-test/scene:press-reports! "C-k"))
  (test-user:press! "C-S-DEL")
  (check-equal? '(((editing-test/md:heading () "Head\n") (editing-test/md:para () "First para.\n") (editing-test/md:para () "Second para.\n") (editing-test/md:para () "\n")) ((38 #f)))
    (list (editing-test/scene:blocks) (editing-test/scene:cursors))))

(test "the content starts at the first stop, so kills on the first line keep the first block's opening"
  (editing-test/scene:show! (notes) 4)
  (test-user:press! "C-u 0 C-k")
  (check-equal? '((editing-test/md:heading () "ad\n") ("He")) (list (car (editing-test/scene:blocks)) (editing-test/scene:kills 1)))
  (test-user:press! "C-u 0 C-S-DEL")
  (check-equal? '(editing-test/md:heading () "\n") (car (editing-test/scene:blocks))))

(test "C-d and DEL remove an empty block whole"
  (editing-test/scene:show! (editing-test/md:doc '() (editing-test/md:para '() "a\n") (editing-test/md:para '() "\n") (editing-test/md:para '() "b\n")) 6)
  (test-user:press! "C-d")
  (check-equal? '(((editing-test/md:para () "a\n") (editing-test/md:para () "b\n")) ((6 #f))) (list (editing-test/scene:blocks) (editing-test/scene:cursors)))
  (editing-test/scene:show! (editing-test/md:doc '() (editing-test/md:para '() "a\n") (editing-test/md:para '() "\n") (editing-test/md:para '() "b\n")) 6)
  (test-user:press! "DEL")
  (check-equal? '(((editing-test/md:para () "a\n") (editing-test/md:para () "b\n")) ((3 #f))) (list (editing-test/scene:blocks) (editing-test/scene:cursors))))

(test "C-d and C-k before an atom standing as a block remove it, the cursor staying; DEL after it removes it too"
  (let ([ruled (lambda () (editing-test/md:doc '() (editing-test/md:para '() "ab\n") (editing-test/md:rule '()) (editing-test/md:para '() "cd\n")))])
    (for-each
      (lambda (point keys cursor)
        (editing-test/scene:show! (ruled) point)
        (test-user:press! keys)
        (check-equal? (list '((editing-test/md:para () "ab\n") (editing-test/md:para () "cd\n")) (list (list cursor #f)))
          (list (editing-test/scene:blocks) (editing-test/scene:cursors))))
      '(4 4 8)
      '("C-d" "C-k" "DEL")
      '(4 4 7))))

(test "typing, C-y and DEL then typing over a selected heading give one result, where the deletion leaves the cursor"
  (editing-test/scene:with-setting editing:delete-selection #t
    (lambda ()
      (for-each
        (lambda (keys)
          (editing-test/scene:show! (plan) 9)
          (views:set-mark! (editing-test/scene:view) 2)
          (kill-ring:push! (list "x"))
          (test-user:press! keys)
          (check-equal? '(((editing-test/md:para () "xBuy milk.\n")) ((3 #f))) (list (editing-test/scene:blocks) (editing-test/scene:cursors))))
        '("x" "C-y" "DEL x")))))

(test "M-w, C-w and the primary selection of a heading's line take one kill, the heading whole, which C-y puts back as a heading"
  (editing-test/scene:show! (plan) 9)
  (views:set-mark! (editing-test/scene:view) 2)
  (test-user:press! "C-f C-b")
  (let ([primary (kill-ring:text (list (editing:primary-selection)))])
    (test-user:press! "M-w")
    (let ([copied (editing-test/scene:kills 1)])
      (views:set-mark! (editing-test/scene:view) 2)
      (test-user:press! "C-w")
      (check-equal? '("Plan\n" ("Plan\n") ("Plan\n") ((editing-test/md:para () "Buy milk.\n")))
        (list primary copied (editing-test/scene:kills 1) (editing-test/scene:blocks)))))
  (test-user:press! "C-y")
  (check-equal? '((editing-test/md:heading () "Plan\n") (editing-test/md:para () "Buy milk.\n")) (editing-test/scene:blocks)))

(test "two cursors kill whole blocks"
  (editing-test/scene:show! (editing-test/md:doc '() (editing-test/md:para '() "a\n") (editing-test/md:para '() "b\n") (editing-test/md:para '() "c\n") (editing-test/md:para '() "d\n")) 2 10)
  (test-user:press! "C-S-DEL")
  (check-equal? '(((editing-test/md:para () "b\n") (editing-test/md:para () "d\n")) ((2 #f) (6 #f)) ("a\n\nc\n"))
    (list (editing-test/scene:blocks) (editing-test/scene:cursors) (editing-test/scene:kills 1))))

(test "case commands give each block its line break back"
  (editing-test/scene:show! (editing-test/md:doc '() (editing-test/md:para '() "one\n") (editing-test/md:para '() "two\n")) 2)
  (test-user:press! "M-2 M-u")
  (check-equal? '(((editing-test/md:para () "ONE\n") (editing-test/md:para () "TWO\n")) ((11 #f))) (list (editing-test/scene:blocks) (editing-test/scene:cursors))))

(test "lines in different blocks move and sort as texts: each block keeps its kind"
  (editing-test/scene:show! (editing-test/md:doc '() (editing-test/md:heading '() "b\n") (editing-test/md:para '() "a\n")) 2)
  (test-user:press! "M-<down>")
  (check-equal? '(((editing-test/md:heading () "a\n") (editing-test/md:para () "b\n")) ((6 #f))) (list (editing-test/scene:blocks) (editing-test/scene:cursors)))
  (test-user:press! "M-<up>")
  (check-equal? '(((editing-test/md:heading () "b\n") (editing-test/md:para () "a\n")) ((2 #f))) (list (editing-test/scene:blocks) (editing-test/scene:cursors)))
  (views:set-mark! (editing-test/scene:view) 7)
  (editing-test/scene:run editing:sort-lines)
  (check-equal? '(((editing-test/md:heading () "a\n") (editing-test/md:para () "b\n")) ((2 #f))) (list (editing-test/scene:blocks) (editing-test/scene:cursors))))

(test "a deleting cursor goes to the stop of the earlier of the start asked and the start the deletion fitted"
  (editing-test/scene:show! (sheet) 20)
  (views:set-mark! (editing-test/scene:view) 10)
  (test-user:press! "C-w")
  (check-equal? '(((editing-test/md:para () "Hi\n") (editing-test/md:grid () (editing-test/md:row () (editing-test/md:cell () "a\n") (editing-test/md:cell () "\n"))) (editing-test/md:para () "o\n")) ((10 #f)))
    (list (editing-test/scene:blocks) (editing-test/scene:cursors))))

(test "word motion stops at an isolating node's edge without a word"
  (editing-test/scene:show! (sheet) 9)
  (test-user:press! "M-f")
  (check-equal? '((10 #f)) (editing-test/scene:cursors))
  (check-equal? '() (editing-test/scene:press-reports! "M-f"))
  (check-equal? '((10 #f)) (editing-test/scene:cursors)))

(test "kill-line inside an isolating node ends at its edge with any count, and the buffer keeps the node's line break"
  (for-each
    (lambda (keys)
      (editing-test/scene:show! (editing-test/md:doc '() (editing-test/md:para '() "Hi\n") (editing-test/md:grid '() (editing-test/md:row '() (editing-test/md:cell '() "ab\n") (editing-test/md:cell '() "b\n")))) 10)
      (test-user:press! keys)
      (check-equal? '(((editing-test/md:para () "Hi\n") (editing-test/md:grid () (editing-test/md:row () (editing-test/md:cell () "a\n") (editing-test/md:cell () "b\n")))) ("b"))
        (list (editing-test/scene:blocks) (editing-test/scene:kills 1))))
    '("C-k" "C-u C-k")))

(test "with backward-kill-word-stops-at-whitespace?, M-DEL's run of whitespace passes a block's end, and the deletion joins the blocks as DEL does"
  (editing-test/scene:with-setting editing:backward-kill-word-stops-at-whitespace? #t
    (lambda ()
      (editing-test/scene:show! (editing-test/md:doc '() (editing-test/md:para '() "one \n") (editing-test/md:para '() "  two\n")) 11)
      (test-user:press! "M-DEL")
      (check-equal? '(((editing-test/md:para () "onetwo\n")) ((5 #f))) (list (editing-test/scene:blocks) (editing-test/scene:cursors)))
      (test-user:press! "M-DEL")
      (check-equal? '(((editing-test/md:para () "two\n")) ((2 #f)) ("one")) (list (editing-test/scene:blocks) (editing-test/scene:cursors) (editing-test/scene:kills 1))))))
