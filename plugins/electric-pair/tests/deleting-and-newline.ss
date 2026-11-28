(import (tuna) (test) (test-user) (options) (views) (editing) (chez-scheme) (electric-pair) (sexp-test scene))

(define after sexp-test/scene:after)

(options:set! electric-pair:mode #t)

(test "DEL between an opening character and its closing one deletes both"
  (check-equal? "|" (after "(|)" "DEL"))
  (check-equal? "|" (after "[|]" "DEL"))
  (check-equal? "|" (after "\"|\"" "DEL")))

(test "DEL elsewhere deletes one character"
  (check-equal? "(|)" (after "(a|)" "DEL"))
  (check-equal? "(a|" (after "(a)|" "DEL")))

(test "RET between a pair gives the closing bracket a line of its own"
  (check-equal? "(\n |\n )" (after "(|)" "RET")))

(test "RET with blanks between the opening bracket and the cursor deletes them and still gives the closing bracket its own line"
  (check-equal? "(\n |\n )" (after "(  |)" "RET")))

(test "RET between text and a closing bracket only breaks the line"
  (check-equal? "(a\n |)" (after "(a|)" "RET")))
