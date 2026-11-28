(import (tuna) (test) (test-user) (test-runner) (options) (views) (buffers) (document) (keys) (search) (editing) (echo-area)
        (jump-history) (flash) (flash-test))

(define start "foo fob for\nbar |foo\nfox\nFoo\n")

(define (places) (map cdr (jump-history:places)))

(define (marks-left)
  (list (flash-test:with-attribute "data-flash-label")
        (filter (lambda (f) (member (car f) '("match.other" "flash.backdrop"))) (flash-test:faced))
        (flash-test:prompt)))

(test "a jump labels the matches of what is typed, nearest first and the match at point last, and dims the rest of the view"
  (flash-test:show! start)
  (flash-test:press! "C-c ; f o")
  (check-equal? '("{j}foo {f}fob {s}for" "bar {k}foo" "{a}fox" "{d}Foo" "") (flash-test:lines))
  (check-equal? "Flash [fo] (6): " (flash-test:prompt))
  (check-equal? 6 (length (filter (lambda (f) (equal? f '("match.other" "o"))) (flash-test:faced))))
  (check (member '("flash.backdrop" "bar ") (flash-test:faced)))
  (check (flash-test:quitting! "C-g")))

(test "typing a label moves point to its match, draws no mark of the jump, and records the place left in the jump list"
  (flash-test:show! start)
  (let ([left (views:point (flash-test:view))])
    (flash-test:press! "C-c ; f o a")
    (check-equal? "foo fob for\nbar foo\n|fox\nFoo\n" (flash-test:text))
    (check-equal? (list '() '() #f) (marks-left))
    (check-equal? left (car (places)))))

(test "RET takes the match labelled first"
  (flash-test:show! start)
  (flash-test:press! "C-c ; f o RET")
  (check-equal? "foo fob for\nbar foo\n|fox\nFoo\n" (flash-test:text)))

(test "DEL shortens the pattern and labels its matches; with an empty pattern it changes nothing"
  (flash-test:show! start)
  (flash-test:press! "C-c ; f o x DEL DEL")
  (check-equal? "Flash [f] (6): " (flash-test:prompt))
  (check-equal? '("{j}foo {f}fob {s}for" "bar {k}foo" "{a}fox" "{d}Foo" "") (flash-test:lines))
  (flash-test:press! "DEL DEL")
  (check-equal? "Flash: " (flash-test:prompt))
  (flash-test:press! "f")
  (check-equal? "Flash [f] (6): " (flash-test:prompt))
  (check (flash-test:quitting! "C-g")))

(test "a key the jump does not bind ends it, and then runs"
  (flash-test:show! start)
  (flash-test:press! "C-c ; f o C-e")
  (check-equal? "foo fob for\nbar foo|\nfox\nFoo\n" (flash-test:text))
  (check-equal? (list '() '() #f) (marks-left))
  (flash-test:show! start)
  (flash-test:press! "C-c ; f o <left>")
  (check-equal? "foo fob for\nbar| foo\nfox\nFoo\n" (flash-test:text))
  (flash-test:show! start)
  (flash-test:press! "C-c ; f o")
  (test-user:click! (flash-test:user) (flash-test:view) (flash-test:position 1) "<mouse-1>")
  (check-equal? "f|oo fob for\nbar foo\nfox\nFoo\n" (flash-test:text))
  (check-equal? #f (flash-test:prompt)))

(test "a pattern with a capital matches only its case, as every search's smart case rule"
  (flash-test:show! start)
  (flash-test:press! "C-c ; F o")
  (check-equal? "Flash [Fo] (1): " (flash-test:prompt))
  (check-equal? '("foo fob for" "bar foo" "fox" "{a}Foo" "") (flash-test:lines))
  (check (flash-test:quitting! "C-g")))

(test "a pattern with no match labels nothing, and RET then ends the jump where it started, recording nothing"
  (flash-test:show! start)
  (let ([before (places)])
    (flash-test:press! "C-c ; q")
    (check-equal? "Flash [q] (0): " (flash-test:prompt))
    (flash-test:press! "RET")
    (check-equal? (list start #f before) (list (flash-test:text) (flash-test:prompt) (places)))
    (flash-test:press! "C-c ; RET")
    (check-equal? (list start #f before) (list (flash-test:text) (flash-test:prompt) (places)))))

(test "a space is a character of the pattern"
  (flash-test:show! start)
  (flash-test:press! "C-c ; SPC")
  (check-equal? "Flash [ ] (3): " (flash-test:prompt))
  (check-equal? 3 (length (flash-test:with-attribute "data-flash-label")))
  (check (flash-test:quitting! "C-g")))

(test "a character that follows a match labels nothing, so typing it continues the pattern"
  (flash-test:show! "foa fob\n|x\n")
  (flash-test:press! "C-c ; f")
  (check-equal? '("{s}foa {a}fob" "x" "") (flash-test:lines))
  (flash-test:press! "o")
  (check-equal? '("{s}foa {d}fob" "x" "") (flash-test:lines))
  (flash-test:press! "a")
  (check-equal? "Flash [foa] (1): " (flash-test:prompt))
  (check (flash-test:quitting! "C-g")))

(test "a match keeps its label as the pattern grows, while the label is still allowed"
  (flash-test:show! "|z fx fo\n")
  (flash-test:press! "C-c ; f")
  (check-equal? '("z {a}fx {s}fo" "") (flash-test:lines))
  (flash-test:press! "o")
  (check-equal? '("z fx {s}fo" "") (flash-test:lines))
  (check (flash-test:quitting! "C-g")))

(test "with the region active, the jump extends it to the target"
  (flash-test:show! start)
  (flash-test:press! "C-SPC C-f C-f C-c ; f o")
  (check-equal? '("{k}foo {j}fob {f}for" "bar {a}foo" "{s}fox" "{d}Foo" "") (flash-test:lines))
  (flash-test:press! "s")
  (check-equal? "foo fob for\nbar foo\n|fox\nFoo\n" (flash-test:text))
  (check-equal? (flash-test:position 16) (views:mark (flash-test:view))))

(test "each jump records the place it left, so going back returns to the last jump's start"
  (flash-test:show! start)
  (let ([before (length (places))])
    (flash-test:press! "C-c ; f o a")
    (let ([second-start (views:point (flash-test:view))])
      (flash-test:press! "C-c ; f o d")
      (check-equal? (+ before 2) (length (places)))
      (flash-test:press! "M-,")
      (check-equal? second-start (views:point (flash-test:view))))))

(test "with autojump on, a jump ends as soon as one match is left"
  (options:set! flash:autojump #t)
  (flash-test:show! start)
  (flash-test:press! "C-c ; f o x")
  (check-equal? (list "foo fob for\nbar foo\n|fox\nFoo\n" #f) (list (flash-test:text) (flash-test:prompt)))
  (options:unset! flash:autojump))

(test "the prompt is the jumping client's own, and goes to no log"
  (let ([other (flash-test:open-user)])
    (flash-test:show! start)
    (flash-test:press! "C-c ; f o")
    (check-equal? (list "Flash [fo] (6): " #f) (list (flash-test:prompt) (flash-test:prompt other)))
    (check (flash-test:quitting! "C-g"))
    (let* ([doc (buffers:document (buffers:find "*Messages*"))] [log (buffers:text-between doc 0 (document:length doc))])
      (check (not (exists (lambda (i) (string=? "Flash" (substring log i (+ i 5)))) (iota (max 0 (- (string-length log) 4)))))))))

(test "a capital label is skipped when its letter follows a match under a case rule that ignores case, and given when the rule is exact"
  (options:set! flash:labels "Asdf")
  (flash-test:show! "|foa Foa\n")
  (flash-test:press! "C-c ; f o")
  (check-equal? '("{s}foa {d}Foa" "") (flash-test:lines))
  (check (flash-test:quitting! "C-g"))
  (flash-test:press! "C-c ; F o")
  (check-equal? '("foa {A}Foa" "") (flash-test:lines))
  (check (flash-test:quitting! "C-g"))
  (options:unset! flash:labels))

(test "with dim off, the labels and matches are drawn and nothing is dimmed"
  (options:set! flash:dim #f)
  (flash-test:show! start)
  (flash-test:press! "C-c ; f o")
  (check-equal? 6 (length (flash-test:with-attribute "data-flash-label")))
  (check-equal? '() (filter (lambda (f) (equal? (car f) "flash.backdrop")) (flash-test:faced)))
  (check (flash-test:quitting! "C-g"))
  (options:unset! flash:dim))

(test "with rainbow on, the labels take the numbers 1 to 6 in label order, then 1 again"
  (options:set! flash:rainbow #t)
  (flash-test:show! "|x f1 f2 f3 f4 f5 f6 f7\n")
  (flash-test:press! "C-c ; f")
  (check-equal? '(("a" . "1") ("s" . "2") ("d" . "3") ("f" . "4") ("j" . "5") ("k" . "6") ("l" . "1"))
                (map (lambda (e) (cons (test-user:element-attribute e "data-flash-label") (test-user:element-attribute e "data-flash-rainbow")))
                     (flash-test:with-attribute "data-flash-label")))
  (check (flash-test:quitting! "C-g"))
  (options:unset! flash:rainbow))

(test "a regexp style's unfinished pattern matches nothing and says so; another error gives its message"
  (options:set! flash:style search:regexp)
  (flash-test:show! start)
  (flash-test:press! "C-c ; f o (")
  (check-equal? (list "Flash [fo(] (0) [incomplete input]: " '()) (list (flash-test:prompt) (flash-test:with-attribute "data-flash-label")))
  (flash-test:press! "DEL")
  (check-equal? "Flash [fo] (6): " (flash-test:prompt))
  (check (flash-test:quitting! "C-g"))
  (flash-test:press! "C-c ; *")
  (let ([message (guard (c [(search:pattern-error? c) (condition-message c)])
                   (search:find (views:buffer (flash-test:view)) (search:make-query "*" search:regexp) 1 (search:direction forward)))])
    (check-equal? (string-append "Flash [*] (0) [" message "]: ") (flash-test:prompt)))
  (check (flash-test:quitting! "C-g"))
  (options:unset! flash:style))
