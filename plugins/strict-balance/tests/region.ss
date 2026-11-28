(import (tuna) (test) (test-user) (options) (views) (kill-ring) (editing) (comment) (electric-pair) (strict-balance)
        (editing-test scene) (sexp-test scene))

(define after sexp-test/scene:after)

(options:set! strict-balance:mode #t)

(test "C-w refuses a region that is not balanced and leaves it"
  (sexp-test/scene:show! "(a |b) c@")
  (check-equal? '((strict-balance:kill-region "the region is not balanced")) (editing-test/scene:press-reports! "C-w"))
  (check-equal? "(a |b) c" (sexp-test/scene:shown))
  (check-equal? 8 (sexp-test/scene:mark)))

(test "C-w kills a balanced region"
  (check-equal? "(a (b) |)" (after "(a (b) |c@)" "C-w")))

(test "C-w refuses a region that splits a character literal or a string escape"
  (sexp-test/scene:show! "(a ‸#\\¦( b)" #\‸ #\¦)
  (check-equal? '((strict-balance:kill-region "the region is not balanced")) (editing-test/scene:press-reports! "C-w"))
  (sexp-test/scene:show! "\"a‸\\¦\"b\"" #\‸ #\¦)
  (check-equal? '((strict-balance:kill-region "the region is not balanced")) (editing-test/scene:press-reports! "C-w")))

(test "C-u C-w kills the region whatever it holds"
  (sexp-test/scene:show! "(a ‸#\\¦( b)" #\‸ #\¦)
  (test-user:press! "C-u C-w")
  (check-equal? "(a ‸( b)" (sexp-test/scene:shown #\‸)))

(test "M-w copies an unbalanced region"
  (sexp-test/scene:show! "(a |b) c@")
  (test-user:press! "M-w")
  (check-equal? '("b) c") (editing-test/scene:kills 1)))

(test "typing, C-q, RET and C-y over a region that is not balanced, with delete-selection on, are refused and keep the region"
  (editing-test/scene:with-setting editing:delete-selection #t
    (lambda ()
      (kill-ring:push! (list "y"))
      (for-each
        (lambda (keys)
          (sexp-test/scene:show! "(a |b) c@")
          (check-equal? (list (list (car keys) "the region is not balanced")) (editing-test/scene:press-reports! (cdr keys)))
          (check-equal? "(a |b) c" (sexp-test/scene:shown))
          (check-equal? 8 (sexp-test/scene:mark)))
        (list (cons 'strict-balance:self-insert "x") (cons 'editing:quoted-insert "C-q x")
              (cons 'editing:newline "RET") (cons 'editing:yank "C-y"))))))

(test "a paste and newline-and-indent over a region that is not balanced are refused before anything changes"
  (editing-test/scene:with-setting editing:delete-selection #t
    (lambda ()
      (for-each
        (lambda (run)
          (sexp-test/scene:show! "(a |b) c@")
          (check-equal? (list (list (car run) "the region is not balanced"))
                        (editing-test/scene:reports-during (lambda () (apply editing-test/scene:run (cdr run)))))
          (check-equal? "(a |b) c" (sexp-test/scene:shown)))
        (list (list 'editing:paste editing:paste "y") (list 'editing:newline-and-indent editing:newline-and-indent))))))

(test "C-u forces typing and C-y over a region that is not balanced"
  (editing-test/scene:with-setting editing:delete-selection #t
    (lambda ()
      (kill-ring:push! (list "y"))
      (check-equal? "(a xxxx|" (sexp-test/scene:after "(a |b) c@" "C-u x"))
      (sexp-test/scene:show! "(a |b) c@")
      (test-user:press! "C-u C-y")
      (check-equal? "(a |y" (sexp-test/scene:shown)))))

(test "typing over a balanced region replaces it"
  (editing-test/scene:with-setting editing:delete-selection #t
    (lambda () (check-equal? "(a x|)" (sexp-test/scene:after "(a |b c@)" "x")))))

(test "a second <mouse-3> at the same place refuses to kill a region that is not balanced, as C-w does"
  (sexp-test/scene:show! "(a |b) c")
  (test-user:click! (editing-test/scene:view) 8 "<mouse-3>")
  (check-equal? '((8 4)) (editing-test/scene:cursors))
  (check-equal? '((strict-balance:kill-region "the region is not balanced"))
                (editing-test/scene:reports-during (lambda () (test-user:click! (editing-test/scene:view) 8 "<mouse-3>"))))
  (check-equal? "(a b) c" (editing-test/scene:text)))

(test "a second <mouse-3> at the same place kills a balanced region"
  (sexp-test/scene:show! "(a) |b c")
  (test-user:click! (editing-test/scene:view) 8 "<mouse-3>")
  (test-user:click! (editing-test/scene:view) 8 "<mouse-3>")
  (check-equal? "(a) |" (sexp-test/scene:shown))
  (check-equal? '("b c") (editing-test/scene:kills 1)))

(test "with electric-pair on, a character strict balance leaves to editing still pairs by electric-pair"
  (options:set! electric-pair:mode #t)
  (check-equal? "a \x2018;|\x2019;" (after "a |" "\x2018;"))
  (check-equal? "a (|) b" (after "a |b" "("))
  (options:unset! electric-pair:mode))

(test "M-; puts a comment after the line's code, swallowing no closing bracket"
  (check-equal? (string-append "(a b)" (make-string 35 #\space) ";|") (after "(a b|)" "M-;")))

(test "C-x C-; comments lines whose closing bracket ends a list opened above, unchecked"
  (check-equal? "(f\n  ;; (a))" (begin (after "(f\n  |(a))" "C-x C-;") (editing-test/scene:text))))

(test "C-M-SPC sets the mark at the sexp's end and leaves the region active"
  (sexp-test/scene:show! "(|a b)")
  (test-user:press! "C-M-SPC")
  (check-equal? '((2 3)) (editing-test/scene:cursors)))

(test "C-w over a line comment's line break, before balanced text, kills it as DEL deletes it"
  (sexp-test/scene:show! "(f ; c|\n@(x)\n )")
  (test-user:press! "C-w")
  (check-equal? "(f ; c|(x)\n )" (sexp-test/scene:shown)))

(test "M-y after another command over a region that is not balanced refuses before it asks"
  (editing-test/scene:with-setting editing:delete-selection #t
    (lambda ()
      (kill-ring:push! (list "y"))
      (sexp-test/scene:show! "(a |b) c@")
      (check-equal? '((editing:yank-pop "the region is not balanced")) (editing-test/scene:press-reports! "M-y"))
      (check-equal? "(a |b) c" (sexp-test/scene:shown)))))
