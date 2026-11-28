(import (tuna) (test) (options) (buffers) (search) (search-test))

(define b (search-test:text-buffer "q" "Vector vector-ref  vector\tref (car x)\n"))

(define (all text . more) (search-test:all-in b (apply search:make-query text more)))

(test "a query records its rules when made: the case rule from search:case-fold, the whitespace rule from the lax options by style"
  (let ([q (search:make-query "vector-ref")])
    (check-equal? '("vector-ref" smart lax #f)
                  (list (search:query-text q) (search:query-case q) (search:query-spaces q) (search:query-filter q)))
    (check-equal? search:literal (search:query-style q))
    (check-equal? #f (search:query-partial? q)))
  (check-equal? 'literal (search:query-spaces (search:make-query "a b" search:regexp)))
  (let ([q (search:make-query "(define|lambda)\\b" search:regexp (search:case exact))])
    (check (search:query? q))
    (check-equal? '("(define|lambda)\\b" exact) (list (search:query-text q) (search:query-case q)))
    (check-equal? search:regexp (search:query-style q)))
  (check-equal? 'fold (options:with ([search:case-fold (search:case fold)]) (search:query-case (search:make-query "x"))))
  (check-equal? 'lax (options:with ([search:regexp-lax-whitespace #t]) (search:query-spaces (search:make-query "a b" search:regexp))))
  (let ([q (search:make-query "x")])
    (options:with ([search:case-fold (search:case exact)])
      (check-equal? 'smart (search:query-case q)))))

(test "a case rule that is no rule is refused"
  (check-equal? '(search:make-query "not a case rule" (loud))
                (search-test:raised (lambda () (search:make-query "x" search:literal 'loud)))))

(test "the smart rule ignores case unless the text has a capital; fold always ignores it and exact never does"
  (check-equal? '((1 8 "Vector ") (20 27 "vector\t")) (all "vector "))
  (check-equal? '((1 7 "Vector")) (all "Vector"))
  (check-equal? '((8 14 "vector") (20 26 "vector")) (all "vector" search:literal (search:case exact)))
  (check-equal? '((1 7 "Vector") (8 14 "vector") (20 26 "vector")) (all "VECTOR" search:literal (search:case fold))))

(test "in a regexp only a capital the pattern matches counts, and a case property or POSIX case class makes it exact"
  (let ([smart? (lambda (text) (= 3 (length (all text search:regexp))))])
    (check-equal? '(#t #t #t #t #t #t)
                  (map smart? '("vector\\W" "v\\x{65}ctor" "v\\N{U+0065}ctor" "(?<Year>vector)\\k<Year>?" "(*UCP)vector" "vector(?#Note)")))
    (check-equal? '(#f #f #f #f #f #f)
                  (map smart? '("[V]ector" "\\QVector\\E" "vector\\p{Ll}*" "vector[[:lower:]]*" "vector\\p{Lu}?" "[[:upper:]]?vector")))))

(test "query-caseless? applies the case rule to the buffer"
  (check-equal? '(#t #f #t #f)
                (map (lambda (q) (search:query-caseless? q b))
                     (list (search:make-query "vector") (search:make-query "Vector")
                           (search:make-query "Vector" search:literal (search:case fold))
                           (search:make-query "vector" search:literal (search:case exact))))))

(test "under lax a run of spaces matches search:whitespace; in a regexp only outside brackets and before no quantifier"
  (check-equal? '((20 30 "vector\tref")) (all "vector ref"))
  (check-equal? '() (all "vector ref" search:literal (search:case smart) (search:spaces literal)))
  (check-equal? '((6 9 "r v")) (all "r  v" search:regexp (search:case smart) (search:spaces lax)))
  (check-equal? '((7 9 " v") (18 21 "  v")) (all "[ ]+v" search:regexp (search:case smart) (search:spaces lax)))
  (check-equal? '((15 21 "ref  v")) (all "ref +v" search:regexp (search:case smart) (search:spaces lax))))

(test "a query's own filter, and a filter added that keeps the query's rules"
  (let* ([after-10? (lambda (buffer start end) (> start 10))]
         [before-20? (lambda (buffer start end) (< start 20))]
         [fq (search:make-query "vector" search:literal (search:case exact) (search:spaces literal) after-10?)]
         [both (search:query-with-filter (search:make-query "vector") before-20?)])
    (check-equal? after-10? (search:query-filter fq))
    (check-equal? '((20 26 "vector")) (search-test:all-in b fq))
    (check-equal? '(smart lax ((1 7 "Vector") (8 14 "vector")))
                  (list (search:query-case both) (search:query-spaces both) (search-test:all-in b both)))
    (check-equal? '() (search-test:all-in b (search:query-with-filter fq before-20?)))))

(test "the word style matches whole words, the symbol style whole symbols"
  (check-equal? '((1 7 "Vector") (8 14 "vector") (20 26 "vector")) (all "vector" search:word))
  (check-equal? '((8 18 "vector-ref") (20 30 "vector\tref")) (all "vector ref" search:word))
  (check-equal? '((1 7 "Vector") (20 26 "vector")) (all "vector" search:symbol))
  (check-equal? '((8 18 "vector-ref")) (all "vector-ref" search:symbol))
  (check-equal? '("" "Regexp" "Word" "Symbol")
                (map search:style-description (list search:literal search:regexp search:word search:symbol))))

(test "a query whose end is still being typed asks no boundary after its last word"
  (let ([typing (search:query-with-partial (search:make-query "vec" search:symbol))])
    (check-equal? '() (all "vec" search:symbol))
    (check-equal? #t (search:query-partial? typing))
    (check-equal? '((1 4 "Vec") (8 11 "vec") (20 23 "vec")) (search-test:all-in b typing))
    (check-equal? '((8 17 "vector-re") (20 29 "vector\tre"))
                  (search-test:all-in b (search:query-with-partial (search:make-query "vector re" search:word))))
    (check-equal? #t (search:query-partial? (search:query-with-filter typing (lambda (b s e) #t))))))

(test "a style of one's own receives the text, whether its end is being typed, and the buffer's classes"
  (let* ([flex-pattern (lambda (text partial? classes)
                         (apply string-append
                           (map (lambda (c) (string-append (search:regexp-quote (string c)) "[^\\n]*?"))
                                (string->list text))))]
         [flex (search:make-style "Flex" flex-pattern)])
    (check (search:style? flex))
    (check-equal? "Flex" (search:style-description flex))
    (check-equal? '((1 18 "Vector vector-ref") (20 30 "vector\tref")) (all "vrf" flex)))
  (check-equal? "a\\.b\\*\\(c\\)" (search:regexp-quote "a.b*(c)")))

(test "query-group-count counts a regexp's capturing groups and none of a literal's"
  (check-equal? '(2 0 0 0)
                (map (lambda (q) (search:query-group-count q b))
                     (list (search:make-query "(\\w+)-(\\w+)" search:regexp) (search:make-query "\\(x\\)[(]" search:regexp)
                           (search:make-query "(x)") (search:make-query "(x)" search:word)))))

(test "the history keeps texts newest first, without copies, cut to its length, regexps apart"
  (options:with ([search:history-length 2])
    (for-each (lambda (t) (search:add-to-history! (search:make-query t))) '("one" "two" "one" "three"))
    (search:add-to-history! (search:make-query "a+" search:regexp))
    (check-equal? '(("three" "one") ("a+") ())
                  (list (search:history) (search:regexp-history) (search:prompt-regexp-history)))))

(test "a template's text for a match: groups, the whole match, the count and a backslash; a group that took no part is empty"
  (let ([m (search:find b (search:make-query "(\\w+)-(\\w+)" search:regexp) 0 search-test:forward)])
    (check-equal? "ref-vector vector-ref 7 \\" (search:expand b m "\\2-\\1 \\& \\# \\\\" 7))
    (let-values ([(start end) (search:match-group m 2)])
      (check-equal? '(15 18) (list start end)))
    (check-equal? '(search:expand "not a group of the match's pattern" (3))
                  (search-test:raised (lambda () (search:expand b m "\\3" 0))))
    (check-equal? '(search:expand "a backslash before neither &, #, \\ nor a digit" ("\\q"))
                  (search-test:raised (lambda () (search:expand b m "\\q" 0)))))
  (let ([g (search:find b (search:make-query "(x)|(car)" search:regexp) 0 search-test:forward)])
    (check-equal? "[][car]" (search:expand b g "[\\1][\\2]" 0))))

(test "a pattern PCRE2 refuses raises with its message and offset, at the pattern's end for an unfinished one"
  (let ([pattern-error
         (lambda (text)
           (guard (c [(search:pattern-error? c) (list (condition-message c) (search:pattern-error-offset c))])
             (search:find b (search:make-query text search:regexp) 0 search-test:forward)))])
    (check-equal? '("missing closing parenthesis" 4) (pattern-error "(abc"))
    (check-equal? '("unmatched closing parenthesis" 1) (pattern-error "a)"))))

(test "a pattern error's description is incomplete input at the text's end, else PCRE2's message"
  (let ([described
         (lambda (text)
           (guard (c [(search:pattern-error? c) (search:pattern-error-description c text)])
             (search:find b (search:make-query text search:regexp) 0 search-test:forward)))])
    (check-equal? '("incomplete input" "unmatched closing parenthesis") (map described '("(abc" "a)")))
    (check-raises (lambda (c) (equal? "not a pattern error" (condition-message c))) (search:pattern-error-description 'c "x"))))

(test "search:whitespace is the pattern a run of spaces matches under lax, read when the query is made"
  (let ([q (options:with ([search:whitespace "[ \\t_]+"]) (search:make-query "vector ref"))])
    (check-equal? '((8 18 "vector-ref") (20 30 "vector\tref"))
                  (options:with ([search:whitespace "[-\\t]"]) (search-test:all-in b (search:make-query "vector ref"))))
    (check-equal? '((20 30 "vector\tref")) (search-test:all-in b q))))

(test "a style receives the whitespace pattern under lax and #f under literal, and the symbol characters' class"
  (let* ([seen '()]
         [spy (search:make-style "Spy" (lambda (text partial? classes)
                                         (set! seen (cons (list (search:classes-whitespace classes) (search:classes-symbol classes)) seen))
                                         (search:regexp-quote text)))])
    (search-test:all-in b (search:make-query "x" spy (search:case smart) (search:spaces lax)))
    (search-test:all-in b (search:make-query "x" spy (search:case smart) (search:spaces literal)))
    (check-equal? '("[ \\t]+" #f) (list (car (car (last-pair seen))) (car (car seen))))
    (check (for-all string? (map cadr seen)))))

(test "match-group raises for a group the pattern does not have, and gives #f for one that took no part"
  (let ([g (search:find b (search:make-query "(x)|(car)" search:regexp) 0 search-test:forward)])
    (let-values ([(start end) (search:match-group g 1)])
      (check-equal? '(#f #f) (list start end)))
    (check-raises (lambda (c) #t) (search:match-group g 3))))
