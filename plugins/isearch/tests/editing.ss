(import (tuna) (test) (test-user) (keys) (views) (minibuffer) (kill-ring) (search) (isearch) (isearch-test))

(define here isearch-test:here)

(define (at! p) (views:set-point! (isearch-test:view) p))

(test "M-e reads the text in the minibuffer with the search's keymap off, and C-s or C-r there searches with what was read"
  (isearch-test:show! "e" "Foo bar foo baz Bar\n")
  (test-user:press! "C-s b a")
  (test-user:press! "M-e")
  (check-equal? "ba" (minibuffer:input (minibuffer:current-prompt)))
  (check-equal? #f (keys:prompt (test-user:client)))
  (test-user:press! "z C-s")
  (check-equal? '(16 "I-search: baz" "baz") (here))
  (test-user:press! "M-e")
  (test-user:press! "DEL DEL DEL f o o C-r")
  (check-equal? '(9 "I-search backward: foo" "foo") (here))
  (test-user:press! "RET"))

(test "RET in M-e's prompt searches from the current match's start"
  (isearch-test:show! "e" "foo x foo y foo x\n")
  (test-user:press! "C-s f o o C-s")
  (test-user:press! "M-e")
  (test-user:type! " x")
  (test-user:press! "RET")
  (check-equal? '(18 "I-search: foo x" "foo x") (here))
  (test-user:press! "RET"))

(test "a quit in M-e's prompt of a successful search cancels it, point back at the origin"
  (isearch-test:show! "e" "Foo bar foo baz Bar\n")
  (test-user:press! "C-s b a M-e")
  (check (isearch-test:cancelling! "C-g"))
  (check-equal? '(1 #f #f) (here)))

(test "with no text typed, RET reads the text and searches once"
  (isearch-test:show! "e" "Foo bar foo baz Bar\n")
  (test-user:press! "C-s RET")
  (test-user:type! "baz")
  (test-user:press! "RET")
  (check-equal? '(16 #f) (list (isearch-test:point) (keys:prompt (test-user:client)))))

(test "M-c switches between the fold and exact case rules and says which in the prompt; under smart it turns from the rule in effect"
  (isearch-test:show! "e" "Foo bar foo baz Bar\n")
  (test-user:press! "C-s f o o")
  (check-equal? '(4 "I-search: foo" "Foo") (here))
  (test-user:press! "M-c")
  (check-equal? '(12 "I-search: foo [case sensitive]" "foo") (here))
  (test-user:press! "M-c")
  (check-equal? '(12 "I-search: foo [case insensitive]" "foo") (here))
  (test-user:press! "RET")
  (at! 1)
  (test-user:press! "C-s B a r")
  (check-equal? '(20 "I-search: Bar" "Bar") (here))
  (test-user:press! "M-c")
  (check-equal? '(20 "I-search: Bar [case insensitive]" "Bar") (here))
  (test-user:press! "RET"))

(test "M-r switches to and from regexp, and M-s w to a word search, each searching again"
  (isearch-test:show! "e" "Foo bar foo baz Bar\n")
  (test-user:press! "C-s f . o")
  (check-equal? '(2 "Failing I-search: f{.o}" "F") (here))
  (test-user:press! "M-r")
  (check-equal? '(4 "Regexp I-search: f.o" "Foo") (here))
  (test-user:press! "M-r")
  (check-equal? '(4 "Failing I-search: f.o" "Foo") (here))
  (test-user:press! "C-M-d C-M-d C-M-d b a")
  (test-user:press! "M-s w")
  (check-equal? '(7 "Failing word I-search: ba" "ba") (here))
  (test-user:press! "RET"))

(test "M-c reads the case rule in effect from search, which counts no capital in an escape such as \\W"
  (isearch-test:show! "cw" "a foo b FOO\n")
  (test-user:press! "C-M-s \\ W f o o C-s")
  (check-equal? '(12 "Regexp I-search: \\Wfoo" " FOO") (here))
  (test-user:press! "M-c")
  (check-equal? '(12 "Failing regexp I-search: \\Wfoo [case sensitive]" " FOO") (here))
  (test-user:press! "C-s")
  (check-equal? '(6 "Overwrapped regexp I-search: \\Wfoo [case sensitive]" " foo") (here))
  (test-user:press! "RET"))

(test "M-s SPC switches lax whitespace"
  (isearch-test:show! "ws" "a  b a b\n")
  (test-user:press! "C-s a SPC b")
  (check-equal? '(5 "I-search: a b" "a  b") (here))
  (test-user:press! "M-s SPC")
  (check-equal? '(9 "I-search: a b" "a b") (here))
  (test-user:press! "RET"))

(test "C-w adds the next word after the match, downcased under the smart rule; C-M-y adds a character"
  (isearch-test:show! "y" "Find This-Word now, Next.\n")
  (test-user:press! "C-s f i n d SPC C-w")
  (check-equal? '(10 "I-search: find this" "Find This") (here))
  (test-user:press! "C-M-y")
  (check-equal? '(11 "I-search: find this-" "Find This-") (here))
  (test-user:press! "RET"))

(test "M-s C-e adds the rest of the line"
  (isearch-test:show! "y" "Find This-Word now, Next.\n")
  (test-user:press! "C-s M-s C-e")
  (check-equal? '(26 "I-search: find this-word now, next." "Find This-Word now, Next.") (here))
  (test-user:press! "RET"))

(test "C-y adds the newest kill, and M-y replaces it with the next older"
  (isearch-test:show! "y" "Find This-Word now, Next.\n")
  (kill-ring:push! (list "Next"))
  (kill-ring:push! (list "now"))
  (test-user:press! "C-s C-y")
  (check-equal? '(19 "I-search: now" "now") (here))
  (test-user:press! "M-y")
  (check-equal? '(25 "I-search: next" "Next") (here))
  (test-user:press! "RET"))

(test "M-s M-< goes to the nth match from the start"
  (isearch-test:show! "m" "x a x b x c x\n")
  (at! 8)
  (test-user:press! "C-s x M-s M-<")
  (check-equal? '(2 "I-search: x" "x") (here))
  (test-user:press! "C-u 3 M-s M-<")
  (check-equal? '(10 "I-search: x" "x") (here))
  (test-user:press! "RET"))

(test "ending a search adds its text to search:history, a regexp's to search:regexp-history"
  (isearch-test:show! "h" "abc a.c\n")
  (test-user:press! "C-s a b c RET")
  (at! 1)
  (test-user:press! "C-M-s a . c RET")
  (check-equal? '("abc" "a.c") (list (car (search:history)) (car (search:regexp-history)))))
