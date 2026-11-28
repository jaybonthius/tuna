(import (tuna) (test) (test-user) (options) (views) (editing) (strict-balance) (editing-test scene) (sexp-test scene))

(define after sexp-test/scene:after)

(options:set! strict-balance:mode #t)

(test "DEL refuses the opening bracket of a non-empty list"
  (sexp-test/scene:show! "(|a)")
  (check-equal? '((strict-balance:delete-backward-char "beginning of list")) (editing-test/scene:press-reports! "DEL"))
  (check-equal? "(|a)" (sexp-test/scene:shown)))

(test "DEL moves back into a list or string over its end"
  (check-equal? "(a|)" (after "(a)|" "DEL"))
  (check-equal? "(|)" (after "()|" "DEL"))
  (check-equal? "(\"a|\")" (after "(\"a\"|)" "DEL")))

(test "DEL deletes an empty list or string whole"
  (check-equal? "|" (after "(|)" "DEL"))
  (check-equal? "|" (after "\"|\"" "DEL")))

(test "DEL refuses a string's opening quote"
  (sexp-test/scene:show! "(\"|a\")")
  (check-equal? '((strict-balance:delete-backward-char "beginning of list")) (editing-test/scene:press-reports! "DEL"))
  (check-equal? "(\"|a\")" (sexp-test/scene:shown)))

(test "DEL deletes an escape with its character, and a character literal whole"
  (check-equal? "\"a|b\"" (after "\"a\\\"|b\"" "DEL"))
  (check-equal? "|" (after "#\\(|" "DEL")))

(test "DEL deletes a bracket with no match and says so"
  (sexp-test/scene:show! "a)|")
  (editing-test/scene:take-said!)
  (test-user:press! "DEL")
  (check-equal? "a|" (sexp-test/scene:shown))
  (check-equal? '("deleted a bracket with no match") (editing-test/scene:take-said!))
  (check-equal? "|a" (after "(|a" "DEL")))

(test "a count repeats the rule"
  (check-equal? "(a b|)" (after "(a b c|)" "M-2 DEL")))

(test "C-u DEL deletes one character whatever it is"
  (check-equal? "|a)" (after "(|a)" "C-u DEL")))

(test "DEL with delete-selection on refuses an unbalanced region and leaves it"
  (editing-test/scene:with-setting editing:delete-selection #t
    (lambda ()
      (sexp-test/scene:show! "(a |b c)@")
      (check-equal? '((strict-balance:delete-backward-char "the region is not balanced")) (editing-test/scene:press-reports! "DEL"))
      (check-equal? "(a |b c)" (sexp-test/scene:shown))
      (check-equal? 8 (sexp-test/scene:mark)))))

(test "with editing's region rules off, DEL ignores the region and deletes by the rules above"
  (editing-test/scene:with-setting editing:delete-active-region #f
    (lambda () (check-equal? "(a|b c)" (after "(a |b c)@" "DEL")))))

(test "DEL deletes a balanced region"
  (check-equal? "(| c)" (after "(|a b@ c)" "DEL")))

(test "C-d and <delete> move into a list"
  (check-equal? "(|a)" (after "|(a)" "C-d"))
  (check-equal? "(|a)" (after "|(a)" "<delete>")))

(test "C-d refuses the end of a list, and deletes an empty one"
  (sexp-test/scene:show! "(a|)")
  (check-equal? '((strict-balance:delete-char "end of list")) (editing-test/scene:press-reports! "C-d"))
  (check-equal? "|" (after "(|)" "C-d")))

(test "C-d moves into a string, deletes a bracket with no match and says so, and a character literal whole"
  (check-equal? "\"|ab\"" (after "|\"ab\"" "C-d"))
  (editing-test/scene:take-said!)
  (check-equal? "a|" (after "a|)" "C-d"))
  (check-equal? '("deleted a bracket with no match") (editing-test/scene:take-said!))
  (check-equal? "|" (after "|#\\(" "C-d")))

(test "C-d with delete-selection off ignores the region"
  (check-equal? "(a |) c" (after "(a |b) c@" "C-d")))

(test "two cursors delete by their own rules; one refused does not stop the other"
  (check-equal? "(|a) (b|)" (after "(|a) (b)|" "DEL")))

(test "one undo takes back every edit of a command"
  (sexp-test/scene:show! "(a b|)")
  (test-user:press! "; C-/")
  (check-equal? "(a b|)" (sexp-test/scene:shown))
  (sexp-test/scene:show! "(|a b\n c)")
  (test-user:press! "M-2 C-k C-/")
  (check-equal? "(|a b\n c)" (sexp-test/scene:shown)))

(test "with a region at one cursor and none at another, each cursor deletes by its own rule"
  (sexp-test/scene:show! "(a |b c@) (|d)")
  (test-user:press! "DEL")
  (check-equal? "(a |) (|d)" (sexp-test/scene:shown)))
