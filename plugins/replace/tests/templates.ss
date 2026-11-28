(import (tuna) (test) (test-runner) (test-user) (saved) (keys) (views) (minibuffer) (completion) (replace) (isearch-test) (replace-test)
        (minibuffer-test reading) (minibuffer-test screen))

(define asked replace-test:asked)

(define text replace-test:text)

(define (prompt-for from to) (string-append "Query replacing " from " with " to ": (? for help) "))

(test "a regexp replacement expands \\&, \\N and \\#, the count so far, and the prompt shows it for the match"
  (isearch-test:show! "t" "ab-cd ef-gh\n")
  (replace-test:replace! "C-M-%" "(\\w+)-(\\w+)" "\\2-\\1 [\\&] \\#")
  (check-equal? '(6 "Query replacing regexp (\\w+)-(\\w+) with cd-ab [ab-cd] 0: (? for help) " "ab-cd") (asked))
  (test-user:press! "!")
  (check-equal? "cd-ab [ab-cd] 0 gh-ef [ef-gh] 1\n" (text)))

(test "the replacement takes the case of a match in capitals or capitalized, when neither the text nor the replacement has a capital"
  (isearch-test:show! "c" "foo Foo FOO fOO\n")
  (replace-test:replace! "M-%" "foo" "bar baz")
  (test-user:press! "!")
  (check-equal? "bar baz Bar Baz BAR BAZ bar baz\n" (text))
  (check-equal? '("BAR BAZ" "Bar Baz") (list (replace:match-case "bar baz" "FOO") (replace:match-case "bar baz" "Foo Qux"))))

(test "a capital in the text makes the session exact, and the replacement keeps its case"
  (isearch-test:show! "c" "foo Foo FOO\n")
  (replace-test:replace! "M-%" "Foo" "bar")
  (test-user:press! "!")
  (check-equal? "foo bar FOO\n" (text)))

(test "with replace:preserve-case off the replacement keeps its case"
  (isearch-test:show! "c" "foo Foo FOO\n")
  (isearch-test:with-setting replace:preserve-case #f
    (lambda ()
      (replace-test:replace! "M-%" "foo" "bar")
      (test-user:press! "!")))
  (check-equal? "bar bar bar\n" (text)))

(test "e reads a new replacement with the session's keys off; it replaces the current match and is used from then on; E turns case conversion off"
  (isearch-test:show! "e" "foo Foo FOO foo\n")
  (replace-test:replace! "M-%" "foo" "x")
  (test-user:press! "e")
  (test-user:press! "DEL y n ! RET")
  (check-equal? (list "yn! Foo FOO foo\n" (list 8 (prompt-for "foo" "Yn!") "Foo")) (list (text) (asked)))
  (test-user:press! "E")
  (test-user:press! "DEL DEL DEL z RET")
  (check-equal? (list "yn! z FOO foo\n" (list 10 (prompt-for "foo" "z") "FOO")) (list (text) (asked)))
  (test-user:press! "!")
  (check-equal? "yn! z z z\n" (text)))

(test "a quit in e's prompt ends the session"
  (isearch-test:show! "e2" "foo foo\n")
  (replace-test:replace! "M-%" "foo" "x")
  (test-user:press! "e")
  (check (isearch-test:cancelling! "C-g"))
  (check-equal? '(#f "foo foo\n") (list (replace-test:session) (text))))

(test "with C-u only whole words match"
  (isearch-test:show! "w" "foo foobar foo\n")
  (replace-test:replace! "C-u M-%" "foo" "x")
  (test-user:press! "!")
  (check-equal? "x foobar x\n" (text)))

(test "with - the session runs backward from point, point at each match's start"
  (isearch-test:show! "w2" "foo foo foo\n")
  (views:set-point! (isearch-test:view) 9)
  (replace-test:replace! "M-- M-%" "foo" "y")
  (check-equal? (list 5 (prompt-for "foo" "y") "foo") (asked))
  (test-user:press! "y")
  (check-equal? (list "foo y foo\n" (list 1 (prompt-for "foo" "y") "foo")) (list (text) (asked)))
  (test-user:press! "q"))

(test "the default is the last pair, and an empty answer takes it; M-p gives each past pair written from → to, and one chosen gives both"
  (saved:set! replace:history '(("foo" . "y") ("foo" . "x")))
  (isearch-test:show! "h" "aa foo x → y\n")
  (test-user:press! "M-%")
  (check-equal? "Query replace (default foo → y): " (minibuffer-test/screen:question))
  (test-user:press! "M-p")
  (check-equal? "foo → y" (minibuffer-test/reading:input))
  (test-user:press! "M-p")
  (check-equal? "foo → x" (minibuffer-test/reading:input))
  (test-user:press! "RET")
  (check-equal? (list 7 (prompt-for "foo" "x") "foo") (asked))
  (test-user:press! "q")
  (views:set-point! (isearch-test:view) 1)
  (test-user:press! "M-% RET")
  (check-equal? (list 7 (prompt-for "foo" "x") "foo") (asked))
  (test-user:press! "q"))

(test "an arrow typed, even one making a past pair, is text to replace"
  (saved:set! replace:history '(("foo" . "baz")))
  (isearch-test:show! "a" "aa x → y foo → baz\n")
  (replace-test:replace! "M-%" "x → y" "z")
  (check-equal? (list 9 (prompt-for "x → y" "z") "x → y") (asked))
  (test-user:press! "!")
  (check-equal? '("aa z foo → baz\n" ("x → y" . "z")) (list (text) (car (replace:history))))
  (views:set-point! (isearch-test:view) 1)
  (replace-test:replace! "M-%" "foo → baz" "Z")
  (check-equal? (list 15 (prompt-for "foo → baz" "Z") "foo → baz") (asked))
  (test-user:press! "!")
  (check-equal? "aa z Z\n" (text)))

(test "the pairs are never saved in replace:prompt-history, which keeps what was typed; replace:history keeps as many pairs as minibuffer:history-length"
  (saved:set! replace:history (map (lambda (k) (cons (format "f~a" k) (format "t~a" k))) (iota 100)))
  (saved:set! replace:prompt-history '("typed-a" "typed-b"))
  (isearch-test:show! "pb" "foo foo\n")
  (replace-test:replace! "M-%" "foo" "baz")
  (test-user:press! "q")
  (check-equal? '(("baz" "foo" "typed-a" "typed-b") 100 ("foo" . "baz"))
                (list (replace:prompt-history) (length (replace:history)) (car (replace:history)))))

(test "M-r in the first prompt lists the pairs too, and a pair chosen there gives both strings"
  (saved:set! replace:history '(("bb" . "BB")))
  (isearch-test:show! "mr" "aa bb cc\n")
  (test-user:press! "M-% M-r")
  (test-user:type! "bb →")
  (test-user:press! "RET")
  (test-user:press! "RET")
  (check-equal? (list 6 (prompt-for "bb" "BB") "bb") (asked))
  (test-user:press! "!")
  (check-equal? "aa BB cc\n" (text)))

(test "while the text is typed its matches are highlighted in the view, and the highlight goes with the prompt"
  (isearch-test:show! "l" "ab ab ab\n")
  (let ([v (isearch-test:view)])
    (test-user:press! "M-%")
    (test-user:type! "ab")
    (test-runner:wait-until (lambda () (= 3 (length (isearch-test:faced (test-user:client) v)))))
    (check-equal? '(("match.other" "ab") ("match.other" "ab") ("match.other" "ab")) (isearch-test:faced (test-user:client) v))
    (check (isearch-test:cancelling! "C-g"))
    (check-equal? '() (isearch-test:faced (test-user:client) v))))

(test "groups of the match asked about are drawn in search.group-1 and search.group-2"
  (isearch-test:show! "g" "foo-bar\n")
  (replace-test:replace! "C-M-%" "(fo)(o-)" "x")
  (let ([drawn (isearch-test:faced (test-user:client))])
    (check-equal? '("foo-" "fo" "o-")
                  (map (lambda (face) (apply string-append (map cadr (filter (lambda (f) (string=? face (car f))) drawn))))
                       '("replace.match" "search.group-1" "search.group-2"))))
  (test-user:press! "q"))

(test "the session's prompt shows a control character in the text or the replacement as ^X, as the second prompt does"
  (isearch-test:show! "ctl" "a\nb\n")
  (test-user:press! "C-M-% C-q C-j RET")
  (test-user:type! ",")
  (test-user:press! "RET")
  (check-equal? '("Query replacing regexp ^J with ,: (? for help) ") (keys:prompt (test-user:client)))
  (test-user:press! "!")
  (check-equal? "a,b," (text)))
