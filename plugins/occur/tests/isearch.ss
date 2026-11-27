(import (tuna) (test) (test-user) (views) (search) (isearch) (occur) (isearch-test) (occur-test))

(define here isearch-test:here)

(test "M-s o during a search lists its query and keeps the search running: the next C-s repeats it in the source"
  (occur-test:src! "one foo\ntwo foo-bar\nfoo three foo\n")
  (occur-test:listing! (lambda () (test-user:press! "C-s f o o M-s o")))
  (check-equal? '((8 "I-search: foo" "foo") (("src" 8 #t) ("*Occur*" 2 #f))
                  "4 matches in 3 lines for \"foo\" in buffer: src\none foo\ntwo foo-bar\nfoo three foo\n")
                (list (here) (occur-test:wins) (occur-test:listed)))
  (test-user:press! "C-s")
  (check-equal? '(16 "I-search: foo" "foo") (here))
  (test-user:press! "RET"))

(test "a word search is named in the heading and the message"
  (views:set-point! (occur-test:view) 1)
  (occur-test:listing! (lambda () (test-user:press! "M-s w f o o M-s o")))
  (check-equal? '("4 matches in 3 lines for word \"foo\" in buffer: src\none foo\ntwo foo-bar\nfoo three foo\n" "Searched 1 buffer; 4 matches for word \"foo\"")
                (list (occur-test:listed) (occur-test:last-message)))
  (test-user:press! "RET"))

(test "a count adds context"
  (occur-test:src! "a\none foo\nb\nc\nfoo two\nd\n")
  (occur-test:listing! (lambda () (test-user:press! "C-s f o o M-1 M-s o")))
  (check-equal? "2 matches for \"foo\" in buffer: src\na\none foo\nb\nc\nfoo two\nd\n" (occur-test:listed))
  (test-user:press! "RET"))

(test "C-u collects; with groups in a regexp search the template is read with the search's keys off, so characters edit the prompt"
  (views:set-point! (occur-test:view) 1)
  (occur-test:listing! (lambda () (test-user:press! "C-s f o o C-u M-s o")))
  (check-equal? '((10 "I-search: foo" "foo") "2 matches for \"foo\" in buffer: src\nfoo\nfoo\n") (list (here) (occur-test:listed)))
  (test-user:press! "RET")
  (views:set-point! (occur-test:view) 1)
  (test-user:press! "C-M-s ( f ) o o C-u M-s o")
  (check-equal? "Regexp to collect (default \\1): "
                (test-user:element-text (car (test-user:elements (test-user:screen) "minibuffer-question"))))
  (occur-test:listing! (lambda () (test-user:type! "x\\1") (test-user:press! "RET")))
  (check-equal? '((10 "Regexp I-search: (f)oo" "foo") "2 matches for \"(f)oo\" in buffer: src\nxf\nxf\n") (list (here) (occur-test:listed)))
  (test-user:press! "RET"))
