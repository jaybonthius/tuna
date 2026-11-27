(import (tuna) (test) (test-user) (saved) (options) (tables) (minibuffer) (completion) (completion-list) (editing) (sessions))

(saved:define-saved words-history '() list?)

(define (with-read sources thunk)
  (let ([r (sessions:start! (lambda () (completion:read "? " sources words-history)))])
    (thunk (sessions:session))
    (test-user:press! "C-g")
    (check-raises cancelled? (sessions:result r))))

(define (offered sources text)
  (let ([found #f])
    (with-read sources
      (lambda (s)
        (test-user:type! text)
        (sessions:wait-matches s)
        (set! found (sessions:texts s))))
    found))

(define (first-spans sources text)
  (let ([found #f])
    (with-read sources
      (lambda (s)
        (test-user:type! text)
        (set! found (completion:spans s (car (sessions:matches s))))))
    found))

(define commands-like
  (completion:source
    (candidates (vector "file-picker:find-file" "file-picker:find-file-other-view" "files:save-buffer" "files:write-file"))
    (category completion:command-category)))

(test "prefix, substring and flex make starts and contains terms; an empty query makes the empty pattern"
  (check-equal? '((starts "fi")) (completion:prefix "fi"))
  (check-equal? '((contains "fi")) (completion:substring "fi"))
  (check-equal? '((contains "f" "n" "d")) (completion:flex "fnd"))
  (check-equal? '() (completion:prefix ""))
  (check-equal? '() (completion:substring "")))

(test "partial makes each word start the candidate's matching word, and * matches any text"
  (check-equal? '((starts "u" "/l" "/b")) (completion:partial "u/l/b"))
  (check-equal? '((starts "f" "n")) (completion:partial "f*n"))
  (check-equal? '((starts "f" "-r" "-n")) (completion:partial "f-r-n"))
  (check-equal? '() (completion:partial "")))

(test "any-order splits at spaces, a backslash keeping one, and dispatches !, =, ^, ~ and $"
  (check-equal? '("buf" "find file") (completion:components "buf find\\ file"))
  (check-equal? '((face completion.match-0 (contains "buf")) (face completion.match-1 (starts "find")) (not (contains "x")))
    (completion:any-order "buf ^find !x"))
  (check-equal? '((face completion.match-0 (contains "a b")) (face completion.match-1 (contains "x" "y" "z"))
                  (face completion.match-2 (contains "!x")) (face completion.match-3 (ends "y")))
    (completion:any-order "a\\ b ~xyz =!x y$ !"))
  (check-equal? '() (completion:any-order "")))

(test "any-order's components take its faces in turn, starting again after the last; a negated one takes none"
  (check-equal? '((face completion.match-0 (contains "a")) (not (contains "b c")) (face completion.match-1 (contains "d"))
                  (face completion.match-2 (contains "e")) (face completion.match-3 (contains "f")) (face completion.match-0 (contains "g")))
    (completion:any-order "a !b\\ c d e f g"))
  (options:with ([completion:any-order-faces (list completion:match-2)])
    (check-equal? '((face completion.match-2 (contains "a")) (face completion.match-2 (contains "b"))) (completion:any-order "a b")))
  (options:with ([completion:any-order-faces '()])
    (check-equal? '((contains "a") (contains "b")) (completion:any-order "a b"))))

(test "an entry of completion:any-order-dispatch makes a term of a component that starts with its character"
  (tables:set! completion:any-order-dispatch #\, (lambda (rest) (list 'starts rest)))
  (check-equal? '((face completion.match-0 (starts "ab"))) (completion:any-order ",ab"))
  (tables:remove! completion:any-order-dispatch #\,)
  (check-equal? '((face completion.match-0 (contains ",ab"))) (completion:any-order ",ab")))

(test "by default sources try prefix, then partial; buffers, names, identifiers and commands prefix, then substring; locations substring"
  (check-equal? (list completion:prefix completion:partial) (options:default completion:styles))
  (check-equal? (list completion:prefix completion:partial) (completion:styles))
  (for-each
    (lambda (category)
      (check-equal? (list completion:prefix completion:substring) (tables:ref completion:category-default-styles category #f)))
    (list completion:buffer-category completion:name-category completion:identifier-category completion:command-category))
  (check-equal? (list completion:substring) (tables:ref completion:category-default-styles completion:location-category #f)))

(define fruits
  (completion:source (candidates (vector "apple" "apricot" "banana" "blueberry" "cherry" "Cranberry"))))

(test "with any-order, components match in any order: a p, a !p, =ap, ^b, ry$ and ~ape"
  (options:set! completion:styles (list completion:any-order))
  (saved:set! words-history '("apricot"))
  (for-each
    (lambda (typed expected) (check-equal? expected (offered (list fruits) typed)))
    '("a p" "a !p" "=ap" "^b" "ry$" "~ape")
    '(("apricot" "apple") ("banana" "Cranberry") ("apricot" "apple") ("banana" "blueberry") ("cherry" "Cranberry" "blueberry") ("apple")))
  (saved:set! words-history '())
  (options:unset! completion:styles))

(test "a capital letter makes its component case-sensitive; the others ignore case"
  (options:set! completion:styles (list completion:any-order))
  (let ([makes (list (completion:source (candidates (vector "Makefile" "make.sls" "MAKE"))))])
    (check-equal? '("MAKE" "Makefile" "make.sls") (offered makes "make"))
    (check-equal? '("Makefile") (offered makes "Make"))
    (check-equal? '() (offered makes "M sls"))
    (check-equal? '("make.sls") (offered makes "m sls")))
  (check-equal? '("Cranberry") (offered (list fruits) "C"))
  (check-equal? '("Cranberry") (offered (list fruits) "cr"))
  (options:unset! completion:styles))

(test "each component's match is drawn in its face, by its place among the components not negated"
  (options:set! completion:styles (list completion:any-order))
  (check-equal? '((0 4 completion.match-1) (12 16 completion.match-0)) (first-spans (list commands-like) "find file"))
  (check-equal? '((0 4 completion.match-0) (12 16 completion.match-1)) (first-spans (list commands-like) "file find"))
  (check-equal? '((0 1 completion.match-2) (1 4 completion.match-1) (14 16 completion.match-2) (17 21 completion.match-0))
    (first-spans (list commands-like) "!files file$ ^file ~fnd"))
  (options:unset! completion:styles))

(test "other styles' matches carry no face"
  (check-equal? '((0 2 #f) (5 7 #f))
    (first-spans (list (completion:source (candidates (vector "alpha.txt" "beta.txt")) (styles (list completion:partial)))) "al.t")))

(completion:define-category letter-category "Letters.")

(test "each source tries its category's styles: the first style that matches any of its candidates gives its matches"
  (tables:set! completion:category-styles letter-category (list completion:prefix completion:flex))
  (options:set! completion:styles (list completion:substring))
  (with-read
    (list (completion:source (candidates (vector "abc" "xbc")) (category letter-category))
          (completion:source (candidates (vector "abc" "xbc"))))
    (lambda (s)
      (test-user:type! "bc")
      (check-equal? '("abc" "xbc" "abc" "xbc") (sessions:texts s))
      (test-user:type! "x")
      (check-equal? '() (sessions:texts s))))
  (options:unset! completion:styles)
  (tables:remove! completion:category-styles letter-category))

(test "a source's styles clause is tried before its category's styles, which are tried before the defaults"
  (tables:set! completion:category-styles letter-category (list completion:prefix completion:flex))
  (with-read
    (list (completion:source (candidates (vector "one two" "two")) (category letter-category) (styles (list completion:substring))))
    (lambda (s)
      (test-user:type! "tw")
      (check-equal? '("two" "one two") (sessions:texts s))
      (test-user:press! "DEL DEL")
      (test-user:type! "oo")
      (check-equal? '("one two") (sessions:texts s))))
  (tables:remove! completion:category-styles letter-category))

(test "a category's styles come before completion:styles, which still finds what they miss; at its default the category's defaults stand in"
  (options:set! completion:styles (list completion:any-order))
  (tables:set! completion:category-styles completion:command-category (list completion:prefix))
  (check-equal? '("file-picker:find-file" "file-picker:find-file-other-view") (offered (list commands-like) "find file"))
  (tables:remove! completion:category-styles completion:command-category)
  (options:unset! completion:styles)
  (check-equal? '() (offered (list commands-like) "find file"))
  (check-equal? '("file-picker:find-file" "file-picker:find-file-other-view") (offered (list commands-like) "find-file")))
