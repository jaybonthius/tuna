(import (tuna) (test) (test-user) (modes) (views) (sexp) (editing-test scene) (sexp-test scene))

(define after sexp-test/scene:after)
(define press-reports! editing-test/scene:press-reports!)

(test "C-M-f moves over the sexp after the cursor, and a count over that many"
  (check-equal? "(a b)| c" (after "|(a b) c" "C-M-f"))
  (check-equal? "(a b) c| d" (after "|(a b) c d" "M-2 C-M-f")))

(test "C-M-f with no sexp after the cursor in its list, or at the end of the text, raises and does not move"
  (sexp-test/scene:show! "(a b|)")
  (check-equal? '((sexp:forward "no next sexp")) (press-reports! "C-M-f"))
  (check-equal? "(a b|)" (sexp-test/scene:shown))
  (sexp-test/scene:show! "(a b)|")
  (check-equal? '((sexp:forward "no next sexp")) (press-reports! "C-M-f"))
  (check-equal? "(a b)|" (sexp-test/scene:shown)))

(test "C-M-b moves back over the sexp before the cursor"
  (check-equal? "(a b) |c" (after "(a b) c|" "C-M-b")))

(test "a string is one sexp: from inside it, C-M-f goes past its end and C-M-b to its start"
  (check-equal? "(\"hello w\"| x)" (after "(\"he|llo w\" x)" "C-M-f"))
  (check-equal? "(|\"hello w\" x)" (after "(\"he|llo w\" x)" "C-M-b")))

(test "a comment holds no sexps: from inside one, C-M-f and C-M-b move as from its start"
  (check-equal? "(a ; (b c) d\n e|)" (after "(a ; (b| c) d\n e)" "C-M-f"))
  (check-equal? "(|a ; (b c) d\n e)" (after "(a ; (b| c) d\n e)" "C-M-b")))

(test "C-M-u moves back out of the list holding the cursor, and out of a string first"
  (check-equal? "(a |(b c) d)" (after "(a (b |c) d)" "C-M-u"))
  (check-equal? "(a |\"b c\" d)" (after "(a \"b |c\" d)" "C-M-u")))

(test "C-M-u at top level raises"
  (sexp-test/scene:show! "a |b")
  (check-equal? '((sexp:backward-up-list "at top level")) (press-reports! "C-M-u"))
  (check-equal? "a |b" (sexp-test/scene:shown)))

(test "up-list moves out of the list holding the cursor, to its end"
  (sexp-test/scene:show! "(a (b |c) d)")
  (editing-test/scene:run sexp:up-list 1)
  (check-equal? "(a (b c)| d)" (sexp-test/scene:shown)))

(test "C-M-d moves into the next list, past its opening bracket"
  (check-equal? "(a (|b c) d)" (after "(a |(b c) d)" "C-M-d")))

(test "C-M-d with no list after the cursor in its list raises"
  (sexp-test/scene:show! "(a |b c)")
  (check-equal? '((sexp:down-list "at bottom level")) (press-reports! "C-M-d"))
  (sexp-test/scene:show! "(a b |)")
  (check-equal? '((sexp:down-list "at bottom level")) (press-reports! "C-M-d")))

(test "C-M-d with a negative count moves into the previous list, before its closing bracket"
  (check-equal? "(a (b c|) d)" (after "(a (b c) |d)" "M-- C-M-d")))

(test "C-M-n moves past the next list and C-M-p back to the opening bracket of the previous one"
  (check-equal? "(a (b)| (c) d)" (after "(a |(b) (c) d)" "C-M-n"))
  (check-equal? "(a (b) |(c) d)" (after "(a (b) (c) |d)" "C-M-p")))

(test "C-M-a moves to the start of the top-level form around the cursor, or the one before"
  (check-equal? "|(define (f)\n  (g x))\n(h)" (after "(define (f)\n  (g |x))\n(h)" "C-M-a"))
  (check-equal? "|(f)\n\n(h)" (after "(f)\n|\n(h)" "C-M-a")))

(test "C-M-e moves past the end of the top-level form and on to the next line's start"
  (check-equal? "(define (f)\n  (g x))\n|(h)" (after "(define (f)\n  (g |x))\n(h)" "C-M-e"))
  (check-equal? "(f)\n(h)|" (after "(f)\n(h|)" "C-M-e")))

(test "C-M-f moves over a prefix and its list, a datum comment and what follows it, and a character literal"
  (check-equal? "'(a b)| c" (after "|'(a b) c" "C-M-f"))
  (check-equal? "#;(a) (b)|" (after "|#;(a) (b)" "C-M-f"))
  (check-equal? "#\\(| a" (after "|#\\( a" "C-M-f"))
  (check-equal? "(a b]| c" (after "|(a b] c" "C-M-f")))

(test "C-M-f from the start of a block comment moves past the sexp after it"
  (sexp-test/scene:show! "(a ‸#| x |# b)" #\‸ #\¦)
  (test-user:press! "C-M-f")
  (check-equal? "(a #| x |# b‸)" (sexp-test/scene:shown #\‸)))

(test "in a buffer whose mode has no lexer, the commands raise"
  (sexp-test/scene:show-in! modes:fundamental "(a| b)")
  (check-equal? '((sexp:forward "the mode has no lexer")) (press-reports! "C-M-f"))
  (check-equal? '((sexp:kill "the mode has no lexer")) (press-reports! "C-M-k")))

(test "each cursor moves; the command raises only when the primary cursor cannot move"
  (check-equal? "(a| b|)" (after "(|a |b)" "C-M-f"))
  (sexp-test/scene:show! "(a b|) (|c d)")
  (check-equal? '((sexp:forward "no next sexp")) (press-reports! "C-M-f"))
  (check-equal? "(a b|) (c| d)" (sexp-test/scene:shown))
  (sexp-test/scene:show! "(|a b) (c d|)")
  (check-equal? '() (press-reports! "C-M-f"))
  (check-equal? "(a| b) (c d|)" (sexp-test/scene:shown)))

(test "shifted, C-M-f extends a selection"
  (sexp-test/scene:show! "|(a b) c")
  (test-user:press! "C-M-S-<right>")
  (check-equal? '((6 1)) (editing-test/scene:cursors)))
