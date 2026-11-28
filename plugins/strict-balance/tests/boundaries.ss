(import (tuna) (test) (test-user) (options) (keys) (views) (editing) (strict-balance) (editing-test scene) (sexp-test scene))

(define after sexp-test/scene:after)

(options:set! strict-balance:mode #t)

(define (refused marked keys who)
  (sexp-test/scene:show! marked)
  (check-equal? (list (list who "the text moving into or out of a comment, string or symbol is not balanced")) (editing-test/scene:press-reports! keys))
  (check-equal? marked (sexp-test/scene:shown)))

(test "DEL at the start of a line after a trailing comment refuses to pull a closing bracket into the comment"
  (refused "(define (f) ; c\n|  x)" "DEL" 'strict-balance:delete-backward-char))

(test "DEL at the start of a line after a comment joins a balanced line into it"
  (check-equal? "(f ; c|(x)\n )" (after "(f ; c\n|(x)\n )" "DEL")))

(test "C-d at the end of a comment line refuses to pull a closing bracket into the comment"
  (refused "(define (f) ; c|\n  x)" "C-d" 'strict-balance:delete-char))

(test "DEL after a comment's start refuses when the comment's text would be code that is not balanced"
  (refused ";| see (foo" "DEL" 'strict-balance:delete-backward-char)
  (check-equal? "|; see (foo)" (after ";|; see (foo)" "DEL")))

(test "M-d at the end of a comment line refuses to pull a closing bracket into the comment"
  (refused "(f ; c|\nx)" "M-d" 'strict-balance:kill-word))

(test "C-k at the end of a comment line joins the next line when that keeps the brackets"
  (refused "(f ; c|\n x)" "C-k" 'strict-balance:kill-line)
  (check-equal? "(f ; c| (x)\n )" (after "(f ; c|\n (x)\n )" "C-k")))

(test "M-^ refuses to join a line with a closing bracket into the comment above"
  (refused "(f ; c\n |x)" "M-^" 'strict-balance:delete-indentation))

(test "in a string, DEL beside a bracket, a quote or a comment start deletes one character"
  (check-equal? "\"a |b\"" (after "\"a (|b\"" "DEL"))
  (check-equal? "\"(got ~s|\"" (after "\"(got ~s)|\"" "DEL"))
  (check-equal? "\"a |b\"" (after "\"a ;|b\"" "DEL"))
  (check-equal? "\"ab|d\"" (after "\"ab|(d\"" "C-d")))

(test "in a string, an escape and its character go together from either side, and between them"
  (check-equal? "\"a|b\"" (after "\"a\\\"|b\"" "DEL"))
  (check-equal? "\"a|b\"" (after "\"a\\|\"b\"" "DEL"))
  (check-equal? "\"a|b\"" (after "\"a|\\\"b\"" "C-d"))
  (check-equal? "\"a|b\"" (after "\"a\\|\"b\"" "C-d"))
  (check-equal? "\"a\\\\|b\"" (after "\"a\\\\\\\\|b\"" "DEL")))

(test "with several cursors, one at the start of the buffer changes nothing while the others delete"
  (check-equal? "|a (b|)" (after "|a (b)|" "DEL")))

(define (refused-with marked keys who cursor mark)
  (sexp-test/scene:show! marked cursor mark)
  (check-equal? (list (list who "the text moving into or out of a comment, string or symbol is not balanced")) (editing-test/scene:press-reports! keys))
  (check-equal? marked (sexp-test/scene:shown cursor)))

(test "; before a form that ends on a later line puts the form on the next line"
  (check-equal? ";|\n(define (f)\n  x)" (after "|(define (f)\n  x)" ";"))
  (check-equal? "(a ;|\n (b\n c))" (after "(a |(b\n c))" ";")))

(test "RET inside a line comment, before text that is not balanced, continues the comment"
  (check-equal? "(f ; (a\n   ; |) b\n  c)" (after "(f ; (a|) b\n  c)" "RET")))

(test "RET inside a line comment before balanced text breaks the line as usual"
  (check-equal? "(f ; a\n |b\n  c)" (after "(f ; a|b\n  c)" "RET")))

(test "C-o inside a line comment refuses to move text that is not balanced out of it"
  (refused-with "(f ; (a‸) b\n  c)" "C-o" 'editing:open-line #\‸ #\¦))

(test "brackets inside a datum comment keep their partners: deleting or typing one alone is refused"
  (refused-with "#;(a (b)‸)\n(c)" "DEL" 'strict-balance:delete-backward-char #\‸ #\¦)
  (refused-with "#;(a (b‸))\n(c)" "C-d" 'strict-balance:delete-char #\‸ #\¦)
  (refused-with "#;(a (b))‸\n(c)" "DEL" 'strict-balance:delete-backward-char #\‸ #\¦)
  (refused-with "#;(a ‸b)\n(c)" "(" 'strict-balance:self-insert #\‸ #\¦)
  (refused-with "#;(a ‸b)\n(c)" ")" 'strict-balance:self-insert #\‸ #\¦)
  (refused-with "#;(a ‸b)\n(c)" "\"" 'strict-balance:self-insert #\‸ #\¦))

(test "text inside a datum comment that keeps its extent is edited freely"
  (sexp-test/scene:show! "#;(a b‸)\n(c)" #\‸ #\¦)
  (test-user:press! "x DEL DEL")
  (check-equal? "#;(a ‸)\n(c)" (sexp-test/scene:shown #\‸)))

(test "a block comment's end and start are not split"
  (refused-with "(g #| a |#‸ x)" "DEL" 'strict-balance:delete-backward-char #\‸ #\¦)
  (refused-with "(g #| a ‸|# x)" "C-d" 'strict-balance:delete-char #\‸ #\¦)
  (refused-with "(g #|‸ a |# x)" "DEL" 'strict-balance:delete-backward-char #\‸ #\¦))

(test "C-k inside a block comment refuses to kill its end with code after it"
  (refused-with "#| a‸ |# (f\n x)" "C-k" 'strict-balance:kill-line #\‸ #\¦))

(test "typing that starts a block comment before code that is not balanced is refused"
  (refused-with "(a #‸ b)" "|" 'strict-balance:self-insert #\‸ #\¦))

(test "C-j and newline-and-indent inside a line comment follow RET's rule"
  (check-equal? "(f ; (a\n   ; |) b\n  c)" (after "(f ; (a|) b\n  c)" "C-j"))
  (keys:bind! keys:global "C-c n" editing:newline-and-indent)
  (check-equal? "(f ; (a\n   ; |) b\n  c)" (after "(f ; (a|) b\n  c)" "C-c n"))
  (keys:unbind! keys:global "C-c n"))

(test "; before a datum or block comment that ends on a later line breaks the line before it"
  (check-equal? ";|\n#;(define (f)\n  x)\n(g)" (after "|#;(define (f)\n  x)\n(g)" ";"))
  (sexp-test/scene:show! "‸#| a\n b |# (c)" #\‸ #\¦)
  (test-user:press! ";")
  (check-equal? ";‸\n#| a\n b |# (c)" (sexp-test/scene:shown #\‸)))

(test "M-DEL over blanks, with backward-kill-word-stops-at-whitespace?, refuses to pull text into a comment"
  (editing-test/scene:with-setting editing:backward-kill-word-stops-at-whitespace? #t
    (lambda ()
      (sexp-test/scene:show! "(f ; c\n   |x)")
      (check-equal? '((strict-balance:backward-kill-word "the text moving into or out of a comment, string or symbol is not balanced"))
                    (editing-test/scene:press-reports! "M-DEL"))
      (check-equal? "(f ; c\n   |x)" (sexp-test/scene:shown)))))

(test "a missing closing bracket does not go into a line comment"
  (check-equal? "(a ; c\n)|" (after "(a ; c\n  |" ")")))
