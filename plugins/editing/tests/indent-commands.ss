(import (tuna) (test) (test-user) (options) (views) (editing) (chez-scheme) (editing-test scene) (sexp-test scene))

(define after sexp-test/scene:after)

(test "C-M-\\ indents the region's lines, less a last line the region ends at the start of"
  (check-equal? "(define (f)\n  x\n  y)" (begin (after "(define (f)\n|x\n    y@)" "C-M-\\") (editing-test/scene:text)))
  (check-equal? "(define (f)\n  x\n    y)" (begin (after "(define (f)\n|x\n@    y)" "C-M-\\") (editing-test/scene:text))))

(test "C-M-q indents the lines of the sexp after the cursor"
  (check-equal? "(define (f)\n  (g\n   x))" (begin (after "|(define (f)\n (g\n x))" "C-M-q") (editing-test/scene:text))))

(test "indent-defun indents the lines of the top-level form around the cursor"
  (sexp-test/scene:show! "(define (f)\n x|\n y)")
  (editing-test/scene:run editing:indent-defun)
  (check-equal? "(define (f)\n  x\n  y)" (editing-test/scene:text)))

(test "C-x TAB then <right> moves the region's lines a column at a time, until another key"
  (sexp-test/scene:show! "(f\n |a\n b@)")
  (test-user:press! "C-x TAB <right> <right>")
  (check-equal? "(f\n   a\n   b)" (editing-test/scene:text))
  (test-user:press! "C-g <right>")
  (check-equal? "(f\n   a\n   b)" (editing-test/scene:text)))

(test "C-x TAB with a count moves the lines that many columns"
  (check-equal? "(f\n    a\n    b)" (begin (after "(f\n |a\n b@)" "M-3 C-x TAB") (editing-test/scene:text))))

(test "C-j with electric indentation on breaks the line without indenting, as Emacs's electric-newline-and-maybe-indent"
  (check-equal? "(a \n|b)" (after "(a |b)" "C-j")))

(test "newline-and-indent deletes the blanks before the cursor, breaks the line and indents"
  (sexp-test/scene:show! "(a    |b)")
  (editing-test/scene:run editing:newline-and-indent)
  (check-equal? "(a\n |b)" (sexp-test/scene:shown)))

(test "TAB that changes nothing calls editing:tab-fallback"
  (let ([called 0])
    (editing-test/scene:with-setting editing:tab-fallback (lambda () (set! called (+ called 1)))
      (lambda ()
        (sexp-test/scene:show! "(a\n |b)")
        (test-user:press! "TAB")
        (check-equal? 1 called)))))

(test "C-u TAB moves the other lines of the sexp after the line's text by the line's change"
  (check-equal? "(define (f)\n  |(g a\n       b))" (after "(define (f)\n|     (g a\n          b))" "C-u TAB")))
