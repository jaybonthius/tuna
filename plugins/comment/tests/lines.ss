(import (tuna) (test) (test-user) (options) (buffers) (views) (modes) (editing) (comment-syntax) (comment)
        (editing-test scene) (sexp-test scene))

(define after sexp-test/scene:after)

(define spaces (make-string 35 #\space))

(test "M-; on an empty line starts a comment, indented as the line would be"
  (check-equal? "(a)\n;; |" (after "(a)\n|" "M-;"))
  (check-equal? "(f\n  (a)\n  ;; |\n  (b))" (after "(f\n  (a)\n  |\n  (b))" "M-;")))

(test "M-; after code starts a comment at the comment column"
  (check-equal? (string-append "(a b)" spaces ";|") (after "(a b)|" "M-;")))

(test "M-; moves a comment after code to the comment column, the cursor after its start"
  (check-equal? (string-append "(a b)" spaces "; |x") (after "(a b) ; x|" "M-;")))

(test "M-; puts a new comment at the column of the comment after the code on the line above, when that is past the code"
  (check-equal? "(a b)   ; x\n(c d)   ;|" (after "(a b)   ; x\n(c d)|" "M-;")))

(test "M-; on a region comments its lines, and again uncomments them"
  (check-equal? "(a)\n|;; (b)\n;; (c)" (after "(a)\n|(b)\n(c)@" "M-;"))
  (sexp-test/scene:show! "(a)\n|;; (b)\n;; (c)@")
  (test-user:press! "M-;")
  (check-equal? "(a)\n|(b)\n(c)" (sexp-test/scene:shown)))

(test "C-u M-; kills the comment after the code on the cursor's line only, as Emacs's comment-dwim does"
  (check-equal? "(a b)|" (after "(a b) ; x|" "C-u M-;"))
  (check-equal? "(a b)|\n(c) ; y\n(d) ; z" (after "(a b) ; x|\n(c) ; y\n(d) ; z" "C-u M-;")))

(test "a numeric prefix on M-; kills the comments of that many lines"
  (check-equal? "(a b)\n(c)\n|(d) ; z" (begin (after "(a b) ; x|\n(c) ; y\n(d) ; z" "M-2 M-;") (sexp-test/scene:shown))))

(test "C-x C-; comments the cursor's line and moves to the next"
  (check-equal? "(a)\n;; (b)\n|" (after "(a)\n|(b)\n" "C-x C-;")))

(test "C-x C-; uncomments a commented line and moves to the next"
  (check-equal? "(a)\n(b)\n|" (after "(a)\n|;; (b)\n" "C-x C-;")))

(test "C-x C-; with a count comments that many lines"
  (check-equal? ";; (a)\n;; (b)\n|(c)\n" (after "|(a)\n(b)\n(c)\n" "M-2 C-x C-;")))

(test "C-x C-; on an empty line changes no text and moves to the next"
  (check-equal? "\n|(b)\n" (after "|\n(b)\n" "C-x C-;")))

(test "commenting lines puts the comment start at their least indentation"
  (check-equal? "(f\n  ;; (a)\n  |;;   (b))" (after "(f\n  |(a)\n    (b))" "M-2 C-x C-;")))

(test "a line holding a block comment is not commented, so C-x C-; comments it"
  (sexp-test/scene:show! "‸#| x |#\n" #\‸ #\¦)
  (test-user:press! "C-x C-;")
  (check-equal? ";; #| x |#\n‸" (sexp-test/scene:shown #\‸)))

(test "M-j in a comment continues it on the next line"
  (check-equal? ";; abc\n;; |def" (after ";; abc |def" "M-j")))

(test "M-j and C-M-j in code break the line and indent"
  (check-equal? "(a\n |b)" (after "(a |b)" "M-j"))
  (check-equal? "(a\n |b)" (after "(a |b)" "C-M-j")))

(test "comment:kill kills the comment after the code with the blanks before it"
  (sexp-test/scene:show! "(a b) ; x|")
  (editing-test/scene:run comment:kill 1)
  (check-equal? "(a b)|" (sexp-test/scene:shown)))

(test "comment:kill kills a comment alone on its line and indents the line"
  (sexp-test/scene:show! "(a)\n;; foo|\n(b)")
  (editing-test/scene:run comment:kill 1)
  (check-equal? "(a)\n|\n(b)" (sexp-test/scene:shown)))

(test "C-x ; sets the buffer's comment column to the cursor's column"
  (let ([b (sexp-test/scene:show! "(a b)    |")])
    (test-user:press! "C-x ;")
    (check-equal? 9 (buffers:with-buffer b (comment-syntax:column)))))

(test "in a mode with no comment syntax, the commands raise"
  (sexp-test/scene:show-in! modes:fundamental "(a b)|")
  (check-equal? '((comment:dwim "no comment syntax")) (editing-test/scene:press-reports! "M-;")))

(test "with comment:empty-lines, commenting lines comments the empty ones among them"
  (options:set! comment:empty-lines #t)
  (check-equal? ";; a\n;;\n;; b" (begin (sexp-test/scene:show! "|a\n\nb@") (test-user:press! "M-;") (editing-test/scene:text)))
  (options:unset! comment:empty-lines))
