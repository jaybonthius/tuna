(import (tuna) (test) (test-user) (tables) (hooks) (modes) (syntax) (views) (isearch) (isearch-test))

(define here isearch-test:here)

(define (at! p) (views:set-point! (isearch-test:view) p))

(define sy (isearch-test:show! "sy" "(foo-bar x) foo-barz foo-bar\n"))

(test "M-s _ starts a symbol search that, while typed, finds the symbols its text starts; a repeat finds whole symbols"
  (test-user:press! "M-s _")
  (check-equal? '(1 "Symbol I-search: " #f) (here))
  (test-user:type! "foo-bar")
  (check-equal? '(9 "Symbol I-search: foo-bar" "foo-bar") (here))
  (test-user:press! "C-s")
  (check-equal? '(29 "Symbol I-search: foo-bar" "foo-bar") (here))
  (test-user:press! "RET"))

(test "M-s w starts a word search"
  (at! 1)
  (test-user:press! "M-s w b a r")
  (check-equal? '(9 "Word I-search: bar" "bar") (here))
  (test-user:press! "RET"))

(test "M-s . searches for the symbol at point from its start, and a count goes that many matches on"
  (at! 4)
  (test-user:press! "M-s .")
  (check-equal? '(9 "Symbol I-search: foo-bar" "foo-bar") (here))
  (test-user:press! "RET")
  (at! 4)
  (test-user:press! "C-u 1 M-s .")
  (check-equal? '(29 "Symbol I-search: foo-bar" "foo-bar") (here))
  (test-user:press! "RET"))

(test "M-s M-. takes the active region, deactivating it, or else the symbol at point"
  (at! 2)
  (views:set-mark! (isearch-test:view) 5)
  (test-user:press! "M-s M-.")
  (check-equal? '((5 "I-search: foo" "foo") #f) (list (here) (views:mark (isearch-test:view))))
  (test-user:press! "RET")
  (at! 15)
  (test-user:press! "M-s M-.")
  (check-equal? '(21 "I-search: foo-barz" "foo-barz") (here))
  (test-user:press! "RET"))

(test "C-M-w adds the symbol after the match"
  (at! 1)
  (test-user:press! "C-s ( C-M-w")
  (check-equal? '(9 "I-search: (foo-bar" "(foo-bar") (here))
  (test-user:press! "RET"))

(tables:define-table odd-keymap)
(hooks:define-hook odd-hook)
(modes:define-major-mode odd-mode (keymap odd-keymap) (hook odd-hook))
(tables:set! syntax:symbol-characters odd-mode "!")

(test "a mode's own symbol characters decide what M-s ., a symbol search and C-M-w take"
  (let ([o (isearch-test:show! "odd" "foo!bar foo-bar foo!bar\n")])
    (at! 2)
    (test-user:press! "M-s .")
    (check-equal? '(4 "Symbol I-search: foo" "foo") (here))
    (test-user:press! "RET")
    (modes:set-major-mode odd-mode o)
    (at! 2)
    (test-user:press! "M-s .")
    (check-equal? '(8 "Symbol I-search: foo!bar" "foo!bar") (here))
    (test-user:press! "C-s")
    (check-equal? '(24 "Symbol I-search: foo!bar" "foo!bar") (here))
    (test-user:press! "RET")
    (at! 1)
    (test-user:press! "C-s C-M-w")
    (check-equal? '(8 "I-search: foo!bar" "foo!bar") (here))
    (test-user:press! "RET")))

(test "advice on syntax:buffer-symbol-characters reaches them too"
  (let* ([f (isearch-test:show! "f" "foo!bar foo!bar\n")]
         [with-bang (lambda (chars buffer) (if (eq? buffer f) (string-append (chars buffer) "!") (chars buffer)))])
    (advice-add! syntax:buffer-symbol-characters with-bang)
    (at! 2)
    (test-user:press! "M-s .")
    (check-equal? '(8 "Symbol I-search: foo!bar" "foo!bar") (here))
    (test-user:press! "RET")
    (advice-remove! syntax:buffer-symbol-characters with-bang)
    (at! 2)
    (test-user:press! "M-s .")
    (check-equal? '(4 "Symbol I-search: foo" "foo") (here))
    (test-user:press! "RET")))

(test "a backward regexp foo\\b and a backward symbol search from inside foobar do not find that foo; typed, the symbol search finds the symbols its text starts"
  (isearch-test:show! "fb" "foo foobar\n")
  (at! 9)
  (test-user:press! "C-M-r f o o \\ b")
  (check-equal? '(1 "Regexp I-search backward: foo\\b" "foo") (here))
  (test-user:press! "RET")
  (at! 9)
  (test-user:press! "C-r M-s _ f o o")
  (check-equal? '(5 "Symbol I-search backward: foo" "foo") (here))
  (test-user:press! "RET"))
