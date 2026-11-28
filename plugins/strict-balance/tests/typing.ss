(import (tuna) (test) (test-user) (options) (buffers) (views) (modes) (editing) (strict-balance) (editing-test scene) (sexp-test scene))

(define after sexp-test/scene:after)

(options:set! strict-balance:mode #t)

(test "an opening bracket inserts a pair, with spaces before and after where an atom or bracket touches it"
  (check-equal? "a (|) b" (after "a |b" "("))
  (check-equal? "(a (|) b)" (after "(a |b)" "(")))

(test "an opening bracket with a count wraps that many sexps"
  (check-equal? "(a (|b c) d)" (after "(a |b c d)" "M-2 (")))

(test "an opening bracket with a balanced region wraps it; the region is gone"
  (check-equal? "a (|b c)" (after "a |b c@" "("))
  (check-equal? #f (sexp-test/scene:mark)))

(test "an opening bracket or a quote with an unbalanced region raises and leaves the region"
  (for-each
    (lambda (key)
      (sexp-test/scene:show! "(a |b) c@")
      (check-equal? '((strict-balance:self-insert "the region is not balanced")) (editing-test/scene:press-reports! key))
      (check-equal? "(a |b) c" (sexp-test/scene:shown))
      (check-equal? 8 (sexp-test/scene:mark)))
    '("(" "\"")))

(test "in a string or comment an opening bracket goes in alone"
  (check-equal? "\"a (|b\"" (after "\"a |b\"" "("))
  (check-equal? "; a (|" (after "; a |" "(")))

(test "after #\\ a bracket inserts nothing; C-q inserts it"
  (check-equal? "#\\|" (after "#\\|" "("))
  (check-equal? "#\\(|" (after "#\\|" "C-q (")))

(test "an opening bracket joining the lexeme before it gets no space"
  (check-equal? "#(|)" (after "#|" "("))
  (check-equal? "#vu8(|)" (after "#vu8|" "(")))

(test "a closing bracket of either shape moves past the end of the list holding the cursor"
  (check-equal? "(a b)|" (after "(a |b)" ")"))
  (check-equal? "(a b)|" (after "(a |b)" "]")))

(test "a closing bracket deletes the blanks and line breaks before the list's end"
  (check-equal? "(a b)|" (after "(a b  \n |)" ")")))

(test "a closing bracket keeps a comment's line break and moves past the reindented end"
  (check-equal? "(a b ; c\n   )|" (after "(a b ; c\n  |)" ")")))

(test "a closing bracket at top level raises"
  (sexp-test/scene:show! "a |")
  (check-equal? '((strict-balance:self-insert "not inside a list")) (editing-test/scene:press-reports! ")"))
  (check-equal? "a |" (sexp-test/scene:shown)))

(test "a closing bracket in a list that has none inserts the missing one and says so"
  (sexp-test/scene:show! "(a |")
  (editing-test/scene:take-said!)
  (test-user:press! ")")
  (check-equal? "(a)|" (sexp-test/scene:shown))
  (check-equal? '("inserted a missing bracket") (editing-test/scene:take-said!)))

(test "in a string a closing bracket goes in alone"
  (check-equal? "\"a )|b\"" (after "\"a |b\"" ")")))

(test "a quote inserts a pair, moves past a string's closing quote, and is escaped elsewhere in a string"
  (check-equal? "a \"|\"" (after "a |" "\""))
  (check-equal? "\"a\"|" (after "\"a|\"" "\""))
  (check-equal? "\"a \\\"|b\"" (after "\"a |b\"" "\"")))

(test "a quote with a count wraps that many sexps in a string"
  (check-equal? "(a \"|b c\")" (after "(a |b c)" "M-2 \"")))

(test "in a comment a quote goes in alone"
  (check-equal? "; a \"|" (after "; a |" "\"")))

(test "a comment start before a closing bracket puts the bracket on the next line"
  (check-equal? "(a b;|\n   )" (after "(a b|)" ";"))
  (check-equal? "(a ;|b\n )" (after "(a |b)" ";")))

(test "a comment start with no closing bracket after it on the line is just typed"
  (check-equal? ";|(a b)" (after "|(a b)" ";"))
  (check-equal? "\"a ;|b\"" (after "\"a |b\"" ";")))

(test "{ is part of a Scheme symbol, so it goes in alone"
  (check-equal? "a {|" (after "a |" "{")))

(test "with the mode off, or in a buffer with no lexer, a bracket goes in alone and DEL deletes one character"
  (let ([b (sexp-test/scene:show! "a |")])
    (buffers:with-buffer b (options:set-local! strict-balance:mode #f))
    (test-user:press! "(")
    (check-equal? "a (|" (sexp-test/scene:shown)))
  (sexp-test/scene:show-in! modes:fundamental "(|a)")
  (test-user:press! "( DEL DEL")
  (check-equal? "|a)" (sexp-test/scene:shown)))
