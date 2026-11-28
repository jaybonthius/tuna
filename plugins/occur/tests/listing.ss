(import (tuna) (test) (test-user) (hooks) (options) (saved) (buffers) (document) (views) (layout) (layout-split) (minibuffer)
        (completion) (jump-history) (search) (occur) (isearch-test) (occur-test) (minibuffer-test screen))

(define listed occur-test:listed)
(define rx occur-test:rx)
(define occur! occur-test:occur!)

(define (faced-occur) (isearch-test:faced (test-user:client) (occur-test:occur-view)))

(define (faces-of face) (map cadr (filter (lambda (f) (string=? face (car f))) (faced-occur))))

(define (type-answer! keys text)
  (occur-test:listing! (lambda () (test-user:press! keys) (test-user:type! text) (test-user:press! "RET"))))

(test "M-s o asks for a regexp; *Occur* is shown, not selected, the source keeps point, the echo area names the count, no jump is recorded"
  (occur-test:src! "one foo\ntwo\nfoo three foo\nfour\nFoo five\n")
  (views:set-point! (occur-test:view) 5)
  (test-user:press! "M-s o")
  (check-equal? "List lines matching regexp: " (minibuffer-test/screen:question))
  (occur-test:listing! (lambda () (test-user:type! "foo") (test-user:press! "RET")))
  (check-equal? '((("src" 5 #t) ("*Occur*" 2 #f)) "Searched 1 buffer; 4 matches for \"foo\"" ())
                (list (occur-test:wins) (occur-test:last-message) (jump-history:places)))
  (check-equal? "4 matches in 3 lines for \"foo\" in buffer: src\none foo\nfoo three foo\nFoo five\n" (listed))
  (check-equal? "foo" (car (search:prompt-regexp-history))))

(test "point in *Occur* starts on the heading; the heading is its own element, matches are in occur.match and numbers in shadow"
  (check-equal? "" (occur-test:where))
  (check-equal? 2 (views:point (occur-test:occur-view)))
  (check-equal? 1 (length (occur-test:occur-elements "occur-heading")))
  (check-equal? '("foo" "foo" "foo" "Foo") (faces-of "occur.match"))
  (check-equal? '("      1:" "      3:" "      5:") (faces-of "shadow")))

(test "smart case: a capital makes the regexp exact"
  (occur! (rx "Foo") 0 #f)
  (check-equal? "Searched 1 buffer; 1 match for \"Foo\"" (occur-test:last-message)))

(test "the default is the last regexp read; an empty answer and M-n take it"
  (test-user:press! "M-s o")
  (check-equal? "List lines matching regexp (default foo): " (minibuffer-test/screen:question))
  (test-user:press! "M-n")
  (check-equal? "foo" (minibuffer:input (minibuffer:current-prompt)))
  (occur-test:listing! (lambda () (test-user:press! "RET")))
  (check-equal? "Searched 1 buffer; 4 matches for \"foo\"" (occur-test:last-message)))

(test "with no regexp read, the default is the last regexp search, else the last search, quoted"
  (saved:set! search:prompt-regexp-history '())
  (saved:set! search:regexp-history '())
  (saved:set! search:history '("a.b"))
  (test-user:press! "M-s o")
  (check-equal? "List lines matching regexp (default a\\.b): " (minibuffer-test/screen:question))
  (check (isearch-test:cancelling! "C-g"))
  (saved:set! search:regexp-history '("x+"))
  (test-user:press! "M-s o")
  (check-equal? "List lines matching regexp (default x+): " (minibuffer-test/screen:question))
  (check (isearch-test:cancelling! "C-g")))

(test "no match: *Occur* is killed and its view shows its previous buffer; the echo area says so"
  (occur! (rx "zzz") 0 #f)
  (check-equal? '(#f (("src" 5 #t) ("src" 5 #f)) "Searched 1 buffer; no matches for \"zzz\"")
                (list (occur-test:occur-buffer) (occur-test:wins) (occur-test:last-message))))

(test "the empty regexp is refused"
  (check-equal? '(occur:occur "Occur doesn’t work with the empty regexp")
                (let ([r (guard (c [#t (list (condition-who c) (condition-message c))])
                           (views:with-view (occur-test:view) (occur:occur (rx "") 0 #f)))])
                  r)))

(test "listing *Occur* itself renames it first"
  (occur! (rx "foo") 0 #f)
  (occur-test:in-occur!)
  (occur! (rx "foo") 0 #f)
  (check-equal? (list "*Occur*<2>" "5 matches in 4 lines for \"foo\" in buffer: *Occur*<2>\n4 matches in 3 lines for \"foo\" in buffer: src\none foo\nfoo three foo\nFoo five\n")
                (list (buffers:name (views:buffer (occur-test:view))) (listed)))
  (buffers:kill! (buffers:find "*Occur*<2>"))
  (occur-test:only!))

(test "a region is taken exactly: only the matches inside it are counted and highlighted, and a listed line shows its whole text"
  (occur-test:src! "foo1 foo2\nfoo3 foo4 foo9\nfoo5\n")
  (views:set-mark! (occur-test:view) 3)
  (views:set-point! (occur-test:view) 15)
  (occur! (rx "foo[0-9]") 0 #f)
  (check-equal? "2 matches for \"foo[0-9]\" in buffer: src within region: 3-15\nfoo1 foo2\nfoo3 foo4 foo9\n" (listed))
  (check-equal? '("foo2" "foo3") (faces-of "occur.match"))
  (views:set-mark! (occur-test:view) #f))

(test "a count lists context lines around each match with a separator, numbered and dimmed; a negative count lists lines before only"
  (occur-test:src! "a\nb\nX\nc\nd\ne\nf\nX\ng\n")
  (occur! (rx "X") 1 #f)
  (check-equal? "2 matches for \"X\" in buffer: src\nb\nX\nc\nf\nX\ng\n" (listed))
  (check-equal? 1 (length (occur-test:occur-elements "occur-separator")))
  (check-equal? '("      2:" "      3:" "      4:" "      7:" "      8:" "      9:")
                (map test-user:element-text (occur-test:occur-elements "occur-number")))
  (check-equal? '("      2:b" "      4:c" "      7:f" "      9:g")
                (map test-user:element-text
                     (filter (lambda (e) (equal? "shadow" (test-user:element-attribute e "data-face"))) (occur-test:occur-elements "occur-line"))))
  (occur! (rx "X") -1 #f)
  (check-equal? "2 matches for \"X\" in buffer: src\nb\nX\nf\nX\n" (listed)))

(test "occur:context-lines is the count with no prefix, negative too"
  (occur-test:src! "a\nb\nX\nc\nd\ne\nf\nX\ng\n")
  (options:set! occur:context-lines -1)
  (type-answer! "M-s o" "X")
  (options:set! occur:context-lines 0)
  (check-equal? "2 matches for \"X\" in buffer: src\nb\nX\nf\nX\n" (listed)))

(test "listed lines follow clicks and show it; context lines do not"
  (occur-test:src! "a\nb\nX\nc\nd\ne\nf\nX\ng\n")
  (occur! (rx "X") 1 #f)
  (test-user:settle)
  (check-equal? 2 (length (test-user:elements-with (isearch-test:view-element (test-user:client) (occur-test:occur-view)) "data-click"))))

(test "with jump-to-current-line the current line is listed in match.other, matching or not, and point is at its end"
  (occur-test:src! "one foo\ntwo\nfoo three foo\nfour\n")
  (options:set! occur:jump-to-current-line #t)
  (views:set-point! (occur-test:view) 10)
  (occur! (rx "foo") 0 #f)
  (check-equal? '("3 matches in 2 lines for \"foo\" in buffer: src\none foo\ntwo\nfoo three foo\n" "two") (list (listed) (occur-test:where)))
  (check-equal? 1 (length (filter (lambda (e) (equal? "match.other" (test-user:element-attribute e "data-face")))
                                  (occur-test:occur-elements "occur-line"))))
  (views:set-point! (occur-test:view) 2)
  (occur! (rx "foo") 0 #f)
  (options:set! occur:jump-to-current-line #f)
  (check-equal? "one foo" (occur-test:where))
  (check-equal? 1 (length (filter (lambda (e) (equal? "match.other" (test-user:element-attribute e "data-face")))
                                  (occur-test:occur-elements "occur-line")))))

(test "C-u collects: with no group \\& is collected unasked; with groups the template is asked, its history starting \\1"
  (occur-test:src! "one foo\ntwo\nfoo three foo\nfour\n")
  (test-user:press! "C-u M-s o")
  (check-equal? "Collect strings matching regexp (default X): " (minibuffer-test/screen:question))
  (occur-test:listing! (lambda () (test-user:type! "f.o") (test-user:press! "RET")))
  (check-equal? "3 matches in 2 lines for \"f.o\" in buffer: src\nfoo\nfoo\nfoo\n" (listed))
  (test-user:press! "C-u M-s o")
  (test-user:type! "(f)(o)o")
  (test-user:press! "RET")
  (check-equal? "Regexp to collect (default \\1): " (minibuffer-test/screen:question))
  (occur-test:listing! (lambda () (test-user:type! "\\2\\1") (test-user:press! "RET")))
  (check-equal? '("3 matches in 2 lines for \"(f)(o)o\" in buffer: src\nof\nof\nof\n" ("\\2\\1" "\\1"))
                (list (listed) (occur:collect-history))))

(test "a parenthesis that is quoted or in a class opens no group, so \\& is collected unasked"
  (type-answer! "C-u M-s o" "\\Q(\\E|[(]|o")
  (check-equal? '(#f "9 matches in 4 lines for \"\\Q(\\E|[(]|o\" in buffer: src\no\no\no\no\no\no\no\no\no\n")
                (list (minibuffer:current-prompt) (listed))))

(test "occur:listed is called after each listing with matches, g included; g lists again, says so and puts point at the start"
  (let* ([d (occur-test:src! "one foo\ntwo\nfoo three foo\nfour\n")] [seen '()] [note! (lambda (b) (set! seen (cons (buffers:name b) seen)))])
    (hooks:add! occur:listed note!)
    (occur! (rx "foo") 0 #f)
    (occur-test:in-occur!)
    (buffers:replace! d 1 1 "foo zero\n")
    (views:set-point! (occur-test:view) 40)
    (occur-test:listing! (lambda () (test-user:press! "g")))
    (check-equal? '("4 matches in 3 lines for \"foo\" in buffer: src\nfoo zero\none foo\nfoo three foo\n" "Searched 1 buffer; 4 matches for \"foo\"" "" ("*Occur*" "*Occur*"))
                  (list (listed) (occur-test:last-message) (occur-test:where) seen))
    (buffers:replace! d 1 (- (document:length (buffers:document d)) 2) "nothing")
    (occur-test:listing! (lambda () (test-user:press! "g")))
    (check-equal? '(#f "Searched 1 buffer; no matches for \"foo\"" ("*Occur*" "*Occur*"))
                  (list (occur-test:occur-buffer) (occur-test:last-message) seen))
    (hooks:remove! occur:listed note!)))

(test "g after the source is killed says so and kills *Occur*"
  (let ([e (occur-test:src! "one foo\n")])
    (occur! (rx "foo") 0 #f)
    (buffers:kill! e)
    (occur-test:in-occur!)
    (occur-test:listing! (lambda () (test-user:press! "g")))
    (check-equal? '(#f "Searched 0 buffers (1 killed); no matches for \"foo\"")
                  (list (occur-test:occur-buffer) (occur-test:last-message)))))

(test "the message names the regexp however long it is, since one message goes to every client's echo area"
  (occur-test:src! "one foo\n")
  (occur! (rx (string-append "foo|" (make-string 200 #\z))) 0 #f)
  (check-equal? (string-append "Searched 1 buffer; 1 match for \"foo|" (make-string 200 #\z) "\"") (occur-test:last-message)))
