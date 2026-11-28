(import (tuna) (test) (test-user) (options) (views) (modes) (editing) (strict-balance) (editing-test scene) (sexp-test scene))

(define after sexp-test/scene:after)

(options:set! strict-balance:mode #t)

(test "C-k kills the sexps on the line from the cursor, stopping before the list's end"
  (check-equal? "(a |)" (after "(a |b (c))" "C-k"))
  (check-equal? "(a |\n d)" (after "(a |b (c)\n d)" "C-k")))

(test "C-k kills a sexp that runs past the line whole and leaves the rest of that line"
  (check-equal? "(a | d)" (after "(a |(b\n c) d)" "C-k")))

(test "C-k in a string kills to the string's end or the line's"
  (check-equal? "(\"a |\" d)" (after "(\"a |b c\" d)" "C-k"))
  (check-equal? "(\"a |\nc\" d)" (after "(\"a |b\nc\" d)" "C-k")))

(test "C-k in a comment kills to the line's end"
  (check-equal? "(a ; c |\n e)" (after "(a ; c |d\n e)" "C-k")))

(test "C-k at the end of a line joins the next"
  (check-equal? "(a b| c)" (after "(a b|\n c)" "C-k")))

(test "C-k then C-y puts the kill back"
  (check-equal? "(a b|)" (after "(|a b)" "C-k C-y")))

(test "C-k with a count repeats the rule"
  (check-equal? "(| c)" (after "(|a b\n c)" "M-2 C-k")))

(test "C-u C-k kills to the line's end unchecked"
  (check-equal? "(a |\n c)" (after "(a |b\n c)" "C-u C-k")))

(test "M-d and C-<delete> kill the next word, passing over brackets"
  (check-equal? "((|) bar)" (after "(|(foo) bar)" "M-d"))
  (check-equal? "((|) bar)" (after "(|(foo) bar)" "C-<delete>"))
  (check-equal? "(\"foo|\")" (after "(\"foo| bar\")" "M-d")))

(test "M-DEL and C-DEL kill the word before"
  (check-equal? "(foo |)" (after "(foo bar|)" "M-DEL"))
  (check-equal? "(foo |)" (after "(foo bar|)" "C-DEL")))

(test "M-d with no word after the cursor raises"
  (sexp-test/scene:show! "(foo bar|)")
  (check-equal? '((strict-balance:kill-word "no word")) (editing-test/scene:press-reports! "M-d"))
  (check-equal? "(foo bar|)" (sexp-test/scene:shown)))

(test "C-DEL after blanks with backward-kill-word-stops-at-whitespace? deletes the blanks, as editing does"
  (editing-test/scene:with-setting editing:backward-kill-word-stops-at-whitespace? #t
    (lambda () (check-equal? "(a|b)" (after "(a   |b)" "C-DEL")))))

(test "C-S-DEL kills a balanced line"
  (check-equal? "(a)\n|" (after "(a)\n|(b)\n" "C-S-DEL")))

(test "C-S-DEL refuses a line that is not balanced"
  (sexp-test/scene:show! "(define (f)|\n  x)")
  (check-equal? '((strict-balance:kill-whole-line "the line is not balanced")) (editing-test/scene:press-reports! "C-S-DEL"))
  (check-equal? "(define (f)|\n  x)" (sexp-test/scene:shown)))

(test "M-0 C-k kills back to the line's start when that text is balanced, and refuses otherwise"
  (check-equal? "(a\n|c)" (after "(a\n b |c)" "M-0 C-k"))
  (sexp-test/scene:show! "(a\n (b |c))")
  (check-equal? '((strict-balance:kill-line "the text is not balanced")) (editing-test/scene:press-reports! "M-0 C-k")))

(test "C-u M-d kills one word whatever it passes"
  (check-equal? "(|) bar)" (after "(|(foo) bar)" "C-u M-d")))

(test "in a buffer with no lexer, C-u C-k kills four lines as editing does"
  (sexp-test/scene:show-in! modes:fundamental "|a\nb\nc\nd\ne")
  (test-user:press! "C-u C-k")
  (check-equal? "|e" (sexp-test/scene:shown)))

(test "C-k inside an opening bracket such as #( kills the whole list"
  (check-equal? "#|" (after "#|(a b)" "C-k")))

(test "C-d inside an opening bracket such as #( moves into the list"
  (check-equal? "#(| a)" (after "#|( a)" "C-d")))
