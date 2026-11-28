(import (tuna) (test) (tables) (options) (document) (languages) (treesit) (python) (treesit highlight) (treesit-test grammar) (treesit-test session))

(define python python:python)
(define grammar (treesit:grammar-file python))
(treesit-test/grammar:build-python! (languages:grammar-commit python) grammar)

(define excluded (options:default treesit:excluded-captures))

(define (shipped-runs text)
  (treesit-test/session:runs (treesit-test/session:highlighted grammar text (treesit-test/session:shipped) excluded)))

(define queried
  (case-lambda
    [(text query) (queried text query '())]
    [(text query excluded)
     (treesit-test/session:runs
       (treesit-test/session:highlighted grammar text (list (treesit-test/session:query! query)) excluded))]))

(test "each range gets the capture of the later pattern, unless an earlier one has a higher priority"
  (check-equal? '(("x" b)) (queried "x = 1\n" "(identifier) @a\n(identifier) @b\n"))
  (check-equal? '(("x" a)) (queried "x = 1\n" "((identifier) @a (#set! priority 101))\n(identifier) @b\n")))

(test "captures named with _, and spell, nospell, conceal and noconceal, colour nothing and win nothing"
  (check-equal? '(("x" a))
    (queried "x = 1\n"
      "(identifier) @a\n(identifier) @_private\n(identifier) @spell\n(identifier) @nospell\n(identifier) @conceal\n(identifier) @noconceal\n")))

(test "faces nest across ranges, the smallest range's first"
  (check-equal? '(("'a" string) ("\\n" (string.escape string)) ("b'" string))
    (queried "x = 'a\\nb'\n" "(string) @string\n(escape_sequence) @string.escape\n")))

(test "@none takes the faces of larger ranges off its own text, while a range inside it keeps its face"
  (check-equal? '(("f\"v=" string) ("1" number) ("\"" string))
    (queried "f\"v={a + 1}\"\n" "(string) @string\n(interpolation) @none\n(integer) @number\n"))
  (check-equal? '(("x" variable.definition) ("\"v=" string) ("{" punctuation.special) ("1" number) ("}" punctuation.special)
                  ("\"" string))
    (shipped-runs "x = f\"v={a + 1}\"\n")))

(test "a range whose winning capture is excluded gets no face of its own: a larger range's shows through, and the capture it beat does not"
  (check-equal? '(("'a'" string)) (queried "x = 'a'\n" "(string) @string\n(string_content) @x\n(string_content) @y\n" '(y)))
  (check-equal? '(("'" string) ("a" (y string)) ("'" string))
    (queried "x = 'a'\n" "(string) @string\n(string_content) @x\n(string_content) @y\n" '(x))))

(test "excluded names are exact: variable leaves variable.definition coloured"
  (check-equal? '(("x" variable.definition))
    (queried "x = y\n" "(identifier) @variable\n(assignment left: (identifier) @variable.definition)\n" '(variable))))

(test "spans count characters where tree-sitter counts bytes: two-, three- and four-byte characters"
  (check-equal? '(("s" variable.definition) ("'é日😀'" string) ("# 😀" comment) ("n" variable.definition) ("1" number))
    (shipped-runs "s = 'é日😀' # 😀\nn = 1\n")))

(test "the first call answers nothing; then the drawn range comes first, then the rest outward, in positions of the document, an atom one U+FFFC of three bytes"
  (let* ([doc (document:from-datum '(code () "x = 'a" #(pic ()) "é'\n" "y = 1\n" "z = 2\n"))]
         [highlight (make-highlight)]
         [y 11]
         [piece (lambda (drawn)
                  (let-values ([(layers data more)
                                (highlight doc (list grammar "python"
                                                     (map (lambda (f) (cons f #f)) (treesit-test/session:shipped))
                                                     excluded drawn)
                                           '())])
                    (car layers)))])
    (check-equal? "x = 'a\xFFFC;é'\ny = 1\nz = 2\n" (document:text doc))
    (check-equal? "y" (document:text doc y (+ y 1)))
    (check-equal? '(0 0 #()) (piece '()))
    (check-equal? '(10 16 #((10 11 ((face . variable.definition))) (14 15 ((face . number)))))
                  (piece (list (cons y (+ y 6)))))
    (check-equal? '(0 10 #((0 1 ((face . variable.definition))) (4 9 ((face . string))))) (piece '()))
    (check-equal? '(16 22 #((16 17 ((face . variable.definition))) (20 21 ((face . number))))) (piece '()))))
