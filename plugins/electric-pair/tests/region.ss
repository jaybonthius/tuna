(import (tuna) (test) (test-user) (options) (views) (editing) (electric-pair) (sexp-test scene))

(define after sexp-test/scene:after)

(options:set! electric-pair:mode #t)

(test "an opening bracket typed with a region puts the pair around it, the cursor after the opening bracket"
  (check-equal? "a (|b c)" (after "a |b c@" "("))
  (check-equal? #f (sexp-test/scene:mark)))

(test "a closing bracket typed with a region puts the pair around it, the cursor after the closing bracket"
  (check-equal? "a (b c)|" (after "a |b c@" ")")))

(test "a quote typed with a region puts quotes around it"
  (check-equal? "a \"|b c\"" (after "a |b c@" "\"")))
