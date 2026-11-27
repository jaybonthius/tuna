(import (tuna) (test) (test-runner) (test-user) (views) (search) (replace) (isearch-test) (replace-test))

(define asked replace-test:asked)

(define text replace-test:text)

(define (region! mark point)
  (views:set-mark! (isearch-test:view) mark)
  (views:set-point! (isearch-test:view) point))

(define (replace-all! keys from to)
  (replace-test:replace! keys from to)
  (when (replace-test:session) (test-user:press! "!")))

(test "an active region is the range, deactivated, and its end follows the replacements"
  (isearch-test:show! "r" "a a a a a\n")
  (region! 3 8)
  (replace-test:replace! "M-%" "a" "xyz")
  (check-equal? '((4 "Query replacing a with xyz: (? for help) " "a") #f) (list (asked) (views:mark (isearch-test:view))))
  (test-user:press! "!")
  (check-equal? "a xyz xyz xyz a\n" (text)))

(test "the scan, the highlights and the count hold the matches the session asks about, and only those"
  (isearch-test:show! "t" "a a a a a\n")
  (region! 3 8)
  (replace-test:replace! "M-%" "a" "b")
  (let ([sc (replace:session-scan (replace-test:session))])
    (test-runner:wait-until (lambda () (search:scan-done? sc)))
    (check-equal? 3 (search:scan-count sc)))
  (test-runner:wait-until (lambda () (= 3 (length (isearch-test:faced (test-user:client))))))
  (check-equal? '(("replace.match" "a") ("match.other" "a") ("match.other" "a")) (isearch-test:faced (test-user:client)))
  (test-user:press! "q"))

(test "a match crossing the range's end is cut there, and the pattern sees the view's bounds"
  (isearch-test:show! "c" "aaaa\n")
  (region! 1 3)
  (replace-all! "C-M-%" "a+" "b")
  (check-equal? "baa\n" (text))
  (isearch-test:show! "d" "foobar\n")
  (region! 1 4)
  (isearch-test:take-said!)
  (replace-all! "C-M-%" "\\bfoo\\b" "baz")
  (check-equal? '(#f "foobar\n" ("Replaced 0 occurrences")) (list (replace-test:session) (text) (isearch-test:take-said!)))
  (region! 1 4)
  (replace-all! "C-u M-%" "foo" "baz")
  (check-equal? '(#f "foobar\n" ("Replaced 0 occurrences")) (list (replace-test:session) (text) (isearch-test:take-said!))))

(test "C-u M-% user and C-M-% \\buser\\b agree on user_id in fundamental, where _ is no word character"
  (isearch-test:show! "u" "user_id user\n")
  (replace-all! "C-u M-%" "user" "uid")
  (check-equal? "uid_id uid\n" (text))
  (isearch-test:show! "u2" "user_id user\n")
  (replace-all! "C-M-%" "\\buser\\b" "uid")
  (check-equal? "uid_id uid\n" (text))
  (isearch-test:take-said!))

(test "^ does not match at a region's start mid-line"
  (isearch-test:show! "m" "xab ab\n")
  (region! 2 7)
  (isearch-test:take-said!)
  (replace-all! "C-M-%" "^ab" "Z")
  (check-equal? '(#f "xab ab\n" ("Replaced 0 occurrences")) (list (replace-test:session) (text) (isearch-test:take-said!))))

(test "with several cursors that have regions, only matches inside a region are asked about; each region's end follows the replacements before it"
  (isearch-test:show! "s" "a a a a a a\n")
  (region! 1 4)
  (views:set-cursor! (views:add-cursor! (isearch-test:view) 8) 12 8)
  (replace-test:replace! "M-%" "a" "bb")
  (check-equal? '(2 "Query replacing a with bb: (? for help) " "a") (asked))
  (test-user:press! "!")
  (check-equal? "bb bb a a bb bb\n" (text))
  (isearch-test:take-said!))
