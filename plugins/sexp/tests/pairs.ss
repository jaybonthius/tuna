(import (tuna) (test) (test-user) (views) (sexp) (editing-test scene) (sexp-test scene))

(define after sexp-test/scene:after)
(define press-reports! editing-test/scene:press-reports!)

(test "M-( inserts a pair at the cursor, with a space before an atom after it"
  (check-equal? "a (|) b" (after "a |b" "M-("))
  (check-equal? "a (|) b" (after "a |b" "M-0 M-(")))

(test "M-( with a count wraps that many sexps"
  (check-equal? "a (|b c)" (after "a |b c" "M-2 M-(")))

(test "M-( wraps the region, which is then gone, the cursor after the opening bracket"
  (check-equal? "a (|b c)" (after "a |b c@" "M-("))
  (check-equal? #f (sexp-test/scene:mark)))

(test "insert-pair with a negative count wraps the sexps before the cursor"
  (sexp-test/scene:show! "a b|")
  (sexp:insert-pair (editing-test/scene:view) -1 "(" ")")
  (check-equal? "a (|b)" (sexp-test/scene:shown)))

(test "no space goes where the opening bracket joins a lexeme that starts before the cursor"
  (check-equal? "#(|)" (after "#|" "M-("))
  (check-equal? "#vu8(|)" (after "#vu8|" "M-(")))

(test "delete-pair deletes the brackets of the list after the cursor"
  (sexp-test/scene:show! "(a |(b c) d)")
  (editing-test/scene:run sexp:delete-pair)
  (check-equal? "(a |b c d)" (sexp-test/scene:shown)))

(test "check-parens moves to an opening bracket that never closes, and raises"
  (sexp-test/scene:show! "(a b|")
  (check-equal? '((sexp:check-parens "unmatched bracket or quote"))
                (editing-test/scene:reports-during (lambda () (editing-test/scene:run sexp:check-parens))))
  (check-equal? "|(a b" (sexp-test/scene:shown)))

(test "check-parens moves to a closing bracket with no opener"
  (sexp-test/scene:show! "(a b))|")
  (editing-test/scene:reports-during (lambda () (editing-test/scene:run sexp:check-parens)))
  (check-equal? "(a b)|)" (sexp-test/scene:shown)))

(test "check-parens does nothing in balanced text"
  (sexp-test/scene:show! "(a [b] \"c\")|")
  (check-equal? '() (editing-test/scene:reports-during (lambda () (editing-test/scene:run sexp:check-parens))))
  (check-equal? "(a [b] \"c\")|" (sexp-test/scene:shown)))
