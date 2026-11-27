(import (tuna) (test) (test-user) (options) (keys) (views) (editing) (search) (isearch) (isearch-test))

(define here isearch-test:here)

(test "each character searches again from the current match's start; C-s goes to the next match"
  (isearch-test:show! "t" "one two three two one\n")
  (test-user:press! "C-s")
  (check-equal? '(1 "I-search: " #f) (here))
  (test-user:type! "tw")
  (check-equal? '(7 "I-search: tw" "tw") (here))
  (test-user:type! "o")
  (check-equal? '(8 "I-search: two" "two") (here))
  (test-user:press! "C-s")
  (check-equal? '(18 "I-search: two" "two") (here))
  (test-user:press! "RET"))

(test "past the last match the search fails; the next C-s wraps, and a match past the origin again is overwrapped"
  (isearch-test:show! "t" "one two three two one\n")
  (test-user:press! "C-s t w o C-s")
  (test-user:press! "C-s")
  (check-equal? '(18 "Failing I-search: two" "two") (here))
  (test-user:press! "C-s")
  (check-equal? '(8 "Overwrapped I-search: two" "two") (here))
  (test-user:press! "RET"))

(test "DEL goes back one state: text, point, match and direction"
  (isearch-test:show! "t" "one two three two one\n")
  (test-user:press! "C-s t w o C-s C-s C-s")
  (test-user:press! "DEL")
  (check-equal? '(18 "Failing I-search: two" "two") (here))
  (test-user:press! "DEL DEL")
  (check-equal? '(8 "I-search: two" "two") (here))
  (test-user:press! "DEL")
  (check-equal? '(7 "I-search: tw" "tw") (here))
  (test-user:press! "RET")
  (check-equal? '(7 #f #f) (here)))

(test "a count repeats a search key"
  (isearch-test:show! "t" "one two three two one\n")
  (test-user:press! "C-s o n e")
  (check-equal? '(4 "I-search: one" "one") (here))
  (test-user:press! "C-u 2 C-s")
  (check-equal? '(22 "Failing I-search: one" "one") (here))
  (test-user:press! "M-3 C-s")
  (check-equal? '(22 "Failing overwrapped I-search: one" "one") (here))
  (test-user:press! "RET"))

(test "C-u 3 before a character adds it three times"
  (isearch-test:show! "as" "a aa aaa aaaa\n")
  (test-user:press! "C-s C-u 3 a")
  (check-equal? '(9 "I-search: aaa" "aaa") (here))
  (test-user:press! "RET"))

(test "C-s with no text searches for the newest text of the history"
  (isearch-test:show! "as" "a aa aaa aaaa\n")
  (test-user:press! "C-s a a a RET")
  (check-equal? "aaa" (car (search:history)))
  (views:set-point! (isearch-test:view) 1)
  (test-user:press! "C-s C-s")
  (check-equal? '(9 "I-search: aaa" "aaa") (here))
  (test-user:press! "RET"))

(test "C-r searches backward, and turning around puts point at the match's other end"
  (isearch-test:show! "r" "one two three two one\n")
  (views:set-point! (isearch-test:view) 22)
  (test-user:press! "C-r t w")
  (check-equal? '(15 "I-search backward: tw" "tw") (here))
  (test-user:press! "C-r")
  (check-equal? '(5 "I-search backward: tw" "tw") (here))
  (test-user:press! "C-s")
  (check-equal? '(7 "I-search: tw" "tw") (here))
  (test-user:press! "RET"))

(test "the prompt's strings are the program's words, its pairs the text as typed: the part that matched with no face, the rest in isearch.fail"
  (isearch-test:show! "r" "one two three two one\n")
  (test-user:press! "C-s")
  (check-equal? '("I-search: ") (keys:prompt (test-user:client)))
  (test-user:type! "tw")
  (check-equal? '("I-search: " (#f . "tw")) (keys:prompt (test-user:client)))
  (test-user:type! "x")
  (check-equal? (list "Failing I-search: " '(#f . "tw") (cons isearch:fail "x")) (keys:prompt (test-user:client)))
  (test-user:press! "RET"))

(test "with the lazy count on, the prompt starts with the match's number and the total"
  (isearch-test:show! "r" "one two three two one\n")
  (isearch-test:with-setting isearch:lazy-count #t
    (lambda ()
      (test-user:press! "C-s t w")
      (isearch-test:wait-scan)
      (check-equal? '("1/2 I-search: " (#f . "tw")) (keys:prompt (test-user:client)))
      (test-user:press! "RET"))))

(test "C-q adds the next key's character, shown as ^J; TAB adds a tab"
  (isearch-test:show! "q" "a\tb\nc\n")
  (test-user:press! "C-s C-q C-j")
  (check-equal? '("I-search: " (#f . "\n")) (keys:prompt (test-user:client)))
  (check-equal? '(5 "I-search: ^J" "\n") (here))
  (test-user:press! "RET")
  (views:set-point! (isearch-test:view) 1)
  (test-user:press! "C-s TAB")
  (check-equal? '(3 "I-search: ^I" "\t") (here))
  (test-user:press! "RET"))

(test "a paste adds its text"
  (isearch-test:show! "q" "a\tb c\n")
  (test-user:press! "C-s C-q TAB")
  (check-equal? '(3 "I-search: ^I" "\t") (here))
  (keys:run-as-input (test-user:client) editing:paste "b c")
  (test-user:settle)
  (check-equal? '(6 "I-search: ^Ib c" "\tb c") (here))
  (test-user:press! "RET"))

(test "C-M-d deletes the text's last character and searches again from the current match"
  (isearch-test:show! "d" "ab ac abc\n")
  (test-user:press! "C-s a b c")
  (check-equal? '(10 "I-search: abc" "abc") (here))
  (test-user:press! "C-M-d")
  (check-equal? '(9 "I-search: ab" "ab") (here))
  (test-user:press! "RET"))

(test "a capital makes the search exact, and a space matches a run of spaces and tabs"
  (isearch-test:show! "c" "foo Foo a  b\n")
  (test-user:press! "C-s F o o")
  (check-equal? '(8 "I-search: Foo" "Foo") (here))
  (test-user:press! "RET")
  (views:set-point! (isearch-test:view) 1)
  (test-user:press! "C-s a SPC b")
  (check-equal? '(13 "I-search: a b" "a  b") (here))
  (test-user:press! "RET"))
