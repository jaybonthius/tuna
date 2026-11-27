(import (tuna) (test) (hooks) (tables) (modes) (prog) (buffers) (document) (views) (indentation) (indentation-test nesting))

(define (raised? who message)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (message-condition? c) (string=? message (condition-message c)))))

(define (text b) (document:text (buffers:document b)))

(define (nested text)
  (let ([b (buffers:make (buffers:free-name "nested") text)])
    (modes:set-major-mode indentation-test/nesting:mode b)
    b))

(tables:define-table derived-keymap)
(hooks:define-hook derived-hook)
(modes:define-major-mode derived (parent indentation-test/nesting:mode) (keymap derived-keymap) (hook derived-hook))

(test "a blank is a space or a tab, and blanks-end gives the position after the blanks from a start, at most an end"
  (check-equal? '(#t #t #f #f) (map indentation:blank? (list #\space #\tab #\newline 'x)))
  (let ([doc (buffers:document (buffers:make "blanks" " \t x\n"))])
    (check-equal? 4 (indentation:blanks-end doc 1 6))
    (check-equal? 2 (indentation:blanks-end doc 1 2))
    (check-raises (raised? 'indentation:blanks-end "not a range in the document") (indentation:blanks-end doc 3 99))))

(test "indenter looks a mode's indenter up along its ancestry, or gives #f; it takes a mode"
  (check (eq? indentation-test/nesting:indenter (indentation:indenter indentation-test/nesting:mode)))
  (check (eq? indentation-test/nesting:indenter (indentation:indenter derived)))
  (check-equal? #f (indentation:indenter prog:mode))
  (check-equal? #f (indentation:indenter 'nonesuch))
  (check-raises (raised? 'indentation:indenter "not a mode") (indentation:indenter "nesting")))

(test "line! replaces a line's indentation with spaces to the indenter's column"
  (let ([b (nested "(a\n\t  b")])
    (indentation:line! b 6)
    (check-equal? "(a\n  b" (text b))))

(test "a line whose text already starts at its column is not edited, so it keeps its tabs and the buffer stays unmodified"
  (let ([b (buffers:make "tabbed" "(a\n\tb")])
    (modes:set-major-mode indentation-test/nesting:mode b)
    (tables:set! indentation:indenters indentation-test/nesting:mode (lambda (buffer position) 8))
    (let ([version (buffers:version b)])
      (indentation:line! b 5)
      (check-equal? (list version #f "(a\n\tb") (list (buffers:version b) (buffers:modified? b) (text b))))
    (tables:set! indentation:indenters indentation-test/nesting:mode indentation-test/nesting:indenter)))

(test "an indenter that returns #f leaves the line as it is"
  (let ([b (nested "(a\n     b")])
    (tables:set! indentation:indenters indentation-test/nesting:mode (lambda (buffer position) #f))
    (indentation:line! b 6)
    (check-equal? "(a\n     b" (text b))
    (tables:set! indentation:indenters indentation-test/nesting:mode indentation-test/nesting:indenter)))

(test "a cursor of any view showing the buffer in the indentation, or at its end, ends after it; other cursors keep their place in the text"
  (let* ([b (nested "(a\nb c")] [v (views:make b)] [w (views:make b)])
    (views:set-point! v 4)
    (views:set-point! w 6)
    (indentation:line! b 5)
    (check-equal? '("(a\n  b c" 6 8) (list (text b) (views:point v) (views:point w)))
    (views:drop! v)
    (views:drop! w)))

(test "an indenter that raises, or returns neither a column nor #f, raises an indenter-error naming it; a bad argument raises another condition"
  (let ([b (nested "x")])
    (tables:set! indentation:indenters indentation-test/nesting:mode (lambda (buffer position) "two"))
    (check-raises (raised? 'indentation:line! "the indenter returned neither a column nor #f") (indentation:line! b 1))
    (check-raises indentation:indenter-error? (indentation:line! b 1))
    (tables:set! indentation:indenters indentation-test/nesting:mode (lambda (buffer position) (error 'nesting-indenter "no rule")))
    (check-raises (raised? 'indentation:line! "the indenter of indentation-test/nesting:mode raised: Exception in nesting-indenter: no rule")
      (indentation:line! b 1))
    (check-raises indentation:indenter-error? (indentation:line! b 1))
    (tables:set! indentation:indenters indentation-test/nesting:mode (lambda (buffer position) (raise 'no-rule)))
    (check-raises (raised? 'indentation:line! "the indenter of indentation-test/nesting:mode raised: no-rule") (indentation:line! b 1))
    (check-raises (lambda (c) (and (indentation:indenter-error? c) (assertion-violation? c))) (indentation:line! b 1))
    (tables:set! indentation:indenters indentation-test/nesting:mode indentation-test/nesting:indenter)
    (check-raises (raised? 'indentation:line! "not a position in the buffer") (indentation:line! b 9))
    (check-raises (lambda (c) (not (indentation:indenter-error? c))) (indentation:line! b 9))
    (check-raises (raised? 'indentation:lines! "not a buffer") (indentation:lines! 'b))))

(test "lines! indents the lines of a range, or of the whole buffer; empty lines stay empty"
  (let ([b (nested "(a\n(b\n\nc\nd))")])
    (indentation:lines! b 4 6)
    (check-equal? "(a\n  (b\n\nc\nd))" (text b))
    (indentation:lines! b)
    (check-equal? "(a\n  (b\n\n    c\n    d))" (text b))))

(test "lines! keeps each cursor's place: one in the indentation stays, or ends where indentation that shrank past it ends"
  (let* ([b (nested "(a\n      b\nc")] [v (views:make b)] [w (views:make b)])
    (views:set-point! v 4)
    (views:set-point! w 8)
    (indentation:lines! b)
    (check-equal? '("(a\n  b\n  c" 4 6) (list (text b) (views:point v) (views:point w)))
    (views:drop! v)
    (views:drop! w)))

(test "with no indenter, a line gets the indentation of the nearest line above that holds more than blanks, the first line none"
  (let ([b (buffers:make "plain" "  a\n\n    \nb")])
    (indentation:line! b 11)
    (check-equal? "  a\n\n    \n  b" (text b))
    (let ([first (buffers:make "first" "   a")])
      (indentation:line! first 1)
      (check-equal? "a" (text first)))))
