(import (tuna) (test) (test-user) (views) (sexp) (editing-test scene) (sexp-test scene))

(define (after-command marked command . args)
  (sexp-test/scene:show! marked)
  (apply editing-test/scene:run command args)
  (sexp-test/scene:shown))

(define (raised marked command . args)
  (sexp-test/scene:show! marked)
  (editing-test/scene:reports-during (lambda () (apply editing-test/scene:run command args))))

(test "slurp-forward takes the sexps after the list holding the cursor into it"
  (check-equal? "(a (b |c d) e)" (after-command "(a (b |c) d e)" sexp:slurp-forward 1))
  (check-equal? "(a (b |c d e))" (after-command "(a (b |c) d e)" sexp:slurp-forward 2))
  (check-equal? '((sexp:slurp-forward "no next sexp")) (raised "(a (b |c))" sexp:slurp-forward 1)))

(test "barf-forward gives up the list's last sexps"
  (check-equal? "(a (b |c) d)" (after-command "(a (b |c d))" sexp:barf-forward 1))
  (check-equal? "(a (b) |c)" (after-command "(a (b |c))" sexp:barf-forward 1))
  (check-equal? '((sexp:barf-forward "no sexp to give up")) (raised "(a (|))" sexp:barf-forward 1)))

(test "slurp-backward takes the sexps before the list into it"
  (check-equal? "(a (b c |d))" (after-command "(a b (c |d))" sexp:slurp-backward 1)))

(test "barf-backward gives up the list's first sexps"
  (check-equal? "(a b (c |d))" (after-command "(a (b c |d))" sexp:barf-backward 1)))

(test "splice deletes the brackets of the list holding the cursor, or the quotes of a string"
  (check-equal? "(a b |c d e)" (after-command "(a (b |c d) e)" sexp:splice))
  (check-equal? "(a b |c d)" (after-command "(a \"b |c\" d)" sexp:splice)))

(test "split makes the list or string holding the cursor two"
  (check-equal? "(a b)| (c)" (after-command "(a b| c)" sexp:split))
  (check-equal? "(\"a b\"| \" c\")" (after-command "(\"a b| c\")" sexp:split)))

(test "join makes two lists, or two strings, beside the cursor one"
  (check-equal? "(a b| c d)" (after-command "(a b)| (c d)" sexp:join))
  (check-equal? "\"a |b\"" (after-command "\"a \"| \"b\"" sexp:join)))

(test "the structure edits raise in a comment, and slurping, barfing and joining in a string"
  (check-equal? '((sexp:slurp-forward "in a string")) (raised "(a \"b |c\" d)" sexp:slurp-forward 1))
  (check-equal? '((sexp:join "in a comment")) (raised "(a ; b| c\n d)" sexp:join))
  (check-equal? '((sexp:splice "in a comment")) (raised "(a ; b| c\n d)" sexp:splice)))
