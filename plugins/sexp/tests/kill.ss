(import (tuna) (test) (test-user) (commands) (views) (sexp) (editing-test scene) (sexp-test scene))

(define after sexp-test/scene:after)
(define press-reports! editing-test/scene:press-reports!)

(test "C-M-k kills the sexp after the cursor as one kill-ring entry"
  (check-equal? "(a | d)" (after "(a |(b c) d)" "C-M-k"))
  (check-equal? '("(b c)") (editing-test/scene:kills 1)))

(test "C-M-k inside a string raises and kills nothing, since the string's closing quote would go"
  (sexp-test/scene:show! "(\"hello| world\" x)")
  (check-equal? '((sexp:kill "in a string")) (press-reports! "C-M-k"))
  (check-equal? "(\"hello| world\" x)" (sexp-test/scene:shown)))

(test "C-M-k with no sexp after the cursor raises"
  (sexp-test/scene:show! "(a b |)")
  (check-equal? '((sexp:kill "no next sexp")) (press-reports! "C-M-k"))
  (check-equal? "(a b |)" (sexp-test/scene:shown)))

(test "C-M-DEL kills back to the start of the sexp before the cursor"
  (check-equal? "(a |d)" (after "(a (b c) |d)" "C-M-DEL")))

(test "two C-M-k in a row make one entry, which C-y puts back"
  (check-equal? "( c)" (begin (sexp-test/scene:show! "(|a b c)") (test-user:press! "C-M-k C-M-k") (editing-test/scene:text)))
  (test-user:press! "C-y")
  (check-equal? "(a b| c)" (sexp-test/scene:shown)))

(test "C-M-t swaps the sexps before and after the cursor and moves past both"
  (check-equal? "(a c b|)" (after "(a b| c)" "C-M-t"))
  (check-equal? "((b) (a)|)" (after "((a) |(b))" "C-M-t")))

(test "C-M-SPC marks the sexp after point, and again the one after that"
  (check-equal? "(| c)" (after "(|a b c)" "C-M-SPC C-M-SPC C-w")))

(test "C-M-SPC leaves an active region ending after the sexp"
  (sexp-test/scene:show! "(|a b c)")
  (test-user:press! "C-M-SPC")
  (check-equal? '((2 3)) (editing-test/scene:cursors)))

(test "C-M-h marks the top-level form around the cursor to the next line's start"
  (check-equal? "(f)\n|(k)" (after "(f)\n(h |x)\n(k)" "C-M-h C-w")))

(test "C-M-h takes the comment lines right above the form"
  (sexp-test/scene:show! "(f)\n;; about h\n(h |x)\n(k)")
  (test-user:press! "C-M-h")
  (check-equal? '((5 22)) (editing-test/scene:cursors)))

(test "raise replaces the list holding the cursor with the sexp after it"
  (sexp-test/scene:show! "(a (b |c) d)")
  (editing-test/scene:run sexp:raise 1)
  (check-equal? "(a |c d)" (sexp-test/scene:shown)))

(test "raise with a region replaces the list with the region"
  (sexp-test/scene:show! "(a (b |c d@) e)")
  (editing-test/scene:run sexp:raise 1)
  (check-equal? "(a |c d e)" (sexp-test/scene:shown)))

(test "transpose, delete-pair and mark raise inside a string and change nothing"
  (for-each
    (lambda (command)
      (sexp-test/scene:show! "(a \"b|c\")")
      (check-equal? (list (list (commands:command-name command) "in a string"))
                    (editing-test/scene:reports-during (lambda () (editing-test/scene:run command))))
      (check-equal? "(a \"b|c\")" (sexp-test/scene:shown))
      (check-equal? #f (sexp-test/scene:mark)))
    (list sexp:transpose sexp:delete-pair sexp:mark))
  (sexp-test/scene:show! "(a \"b|c\")")
  (check-equal? '((sexp:raise "in a string"))
                (editing-test/scene:reports-during (lambda () (editing-test/scene:run sexp:raise 1))))
  (check-equal? "(a \"b|c\")" (sexp-test/scene:shown)))
