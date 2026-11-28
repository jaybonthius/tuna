(import (tuna) (test) (modes) (prog) (buffers) (document) (tables) (syntax) (chez-scheme) (syntax-test)
        (chez-scheme-test scheme-buffers))

(define scheme-buffer chez-scheme-test/scheme-buffers:scheme-buffer)
(define after syntax-test:after)
(define before syntax-test:before)
(define between syntax-test:between)

(define t (scheme-buffer "forms.ss" "(define (f)\n  (g x))\n; note\n(h)\n'(k)\n"))

(test "top-level-forms gives the forms overlapping a range, in order, and the form holding a position"
  (check-equal? '("(define (f)\n  (g x))" "(h)" "'(k)")
                (map (lambda (f) (between t (car f) (cdr f))) (syntax:top-level-forms t 0 (document:length (buffers:document t)))))
  (check-equal? '("(h)") (map (lambda (f) (between t (car f) (cdr f))) (syntax:top-level-forms t (after t "(h") (after t "(h"))))
  (check-equal? '() (syntax:top-level-forms t (after t "note") (after t "note"))))

(test "top-level-forms raises for a range that is not one"
  (check-raises (lambda (c) (and (who-condition? c) (eq? (condition-who c) 'syntax:top-level-forms))) (syntax:top-level-forms t 5 2)))

(define (balanced? text from to)
  (let ([b (scheme-buffer "balance.ss" text)])
    (syntax:balanced? b (after b from) (before b to) "")))

(test "a range is balanced when deleting it keeps the brackets, strings and comments outside it with their partners"
  (check-equal? #t (balanced? "(a (b c) d)" "(a " " d"))
  (check-equal? #t (balanced? "(a \"bcd\" e)" "\"b" "d\""))
  (check-equal? #t (balanced? "(a bc d)" "(a b" " d)")))

(test "a range holding a bracket whose partner is outside is not balanced, nor one joining two lists"
  (check-equal? #f (balanced? "(a (b c) d)" "(a (b" " d)"))
  (check-equal? #f (balanced? "(a) (b)" "(a" "b)")))

(test "a range splitting a character literal or a string escape is not balanced"
  (check-equal? #f (balanced? "(a #\\( b)" "(a " "( b)"))
  (check-equal? #f (balanced? "\"a\\\"b\"" "\"a" "\"b\"")))

(test "a range that moves a closing bracket into a comment is not balanced; one that moves balanced text out of one is"
  (check-equal? #f (balanced? "(a ; c\n b)" "; c" "b)"))
  (check-equal? #t (balanced? "(a ; c\n)" "(a " " c\n"))
  (check-equal? #f (balanced? "(a ; (c\n)" "(a " " (c\n")))

(test "an empty range is balanced"
  (let ([b (scheme-buffer "empty.ss" "(a")])
    (check-equal? #t (syntax:balanced? b 2 2 ""))))

(test "a mode's bracket pairs are its entry's, else its nearest ancestor's, else none"
  (check-equal? '((#\( . #\)) (#\[ . #\])) (syntax:mode-bracket-pairs chez-scheme:mode))
  (check-equal? '() (syntax:mode-bracket-pairs modes:fundamental))
  (let ([own (tables:ref syntax:bracket-pairs chez-scheme:mode #f)])
    (tables:set! syntax:bracket-pairs prog:mode '((#\{ . #\})))
    (tables:remove! syntax:bracket-pairs chez-scheme:mode)
    (check-equal? '((#\{ . #\})) (syntax:mode-bracket-pairs chez-scheme:mode))
    (tables:set! syntax:bracket-pairs chez-scheme:mode own)
    (tables:remove! syntax:bracket-pairs prog:mode)))

(test "mode-bracket-pairs raises for an entry that is not a list of pairs of characters"
  (tables:set! syntax:bracket-pairs modes:fundamental "()")
  (check-raises (lambda (c) (and (who-condition? c) (eq? (condition-who c) 'syntax:mode-bracket-pairs)))
    (syntax:mode-bracket-pairs modes:fundamental))
  (tables:remove! syntax:bracket-pairs modes:fundamental))

(define m (scheme-buffer "match.ss" "(a [b] #\\( \"c\")\n(d e]\nf)"))

(test "lexeme-starting-at and lexeme-ending-at give the lexeme that starts or ends at a position, a one-character bracket included"
  (check-equal? '(open 1 2 1) (syntax-test:lexeme->list (syntax:lexeme-starting-at m 1)))
  (check-equal? '(close 6 7 2) (syntax-test:lexeme->list (syntax:lexeme-ending-at m 7)))
  (check-equal? #f (syntax:lexeme-starting-at m 3))
  (check-equal? '(atom 8 11 1) (syntax-test:lexeme->list (syntax:lexeme-ending-at m 11)))
  (check-equal? '(open 17 18 1) (syntax-test:lexeme->list (syntax:lexeme-starting-at m 17))))

(test "match gives the bracket that matches a bracket, of either shape, or #f"
  (check-equal? '(close 15 16 1) (syntax-test:lexeme->list (syntax:match m (syntax:lexeme-starting-at m 1))))
  (check-equal? '(open 4 5 2) (syntax-test:lexeme->list (syntax:match m (syntax:lexeme-ending-at m 7))))
  (check-equal? #t (syntax:lexeme-mismatched? (syntax:match m (syntax:lexeme-starting-at m 17))))
  (check-equal? #f (syntax:match m (syntax:lexeme-ending-at m 25))))

(test "match raises for a lexeme that is not a bracket of the text"
  (check-raises (lambda (c) (and (who-condition? c) (eq? (condition-who c) 'syntax:match)))
    (syntax:match m (syntax:lexeme-ending-at m 11))))

(test "inserted-lexeme gives what the lexer reads inserted text as, joined to the lexeme before when it joins it"
  (let ([v (scheme-buffer "vector.ss" "(list #vu8 a #\\ b)")])
    (check-equal? '(open 7 12 2) (syntax-test:lexeme->list (syntax:inserted-lexeme v 11 "(")))
    (check-equal? '(atom 14 17 1) (syntax-test:lexeme->list (syntax:inserted-lexeme v 16 "(")))
    (check-equal? '(open 1 2 1) (syntax-test:lexeme->list (syntax:inserted-lexeme v 1 "(")))
    (check-equal? 'string (syntax:lexeme-class (syntax:inserted-lexeme v 13 "\"")))))

(test "match finds the match of a bracket at the start of a line inside a multi-line string, which the questions around a position read as a bracket"
  (let ([d (scheme-buffer "doc.ss" "(define (f)\n  \"Use it as\n(f 1)\n  then\")\n")])
    (let ([open (syntax:lexeme-starting-at d (before d "(f 1)"))])
      (check-equal? 'open (syntax:lexeme-class open))
      (check-equal? '(close 30 31 1) (syntax-test:lexeme->list (syntax:match d open))))))

(test "string-or-comment-at gives the string or comment holding a position, or #f"
  (let ([s (scheme-buffer "strings.ss" "(a \"bc\" ; d\n e)")])
    (check-equal? 'string (syntax:lexeme-class (syntax:string-or-comment-at s (after s "\"b"))))
    (check-equal? 'comment (syntax:lexeme-class (syntax:string-or-comment-at s (after s "; d"))))
    (check-equal? #f (syntax:string-or-comment-at s (after s "(a")))))

(test "a mode's string escape is its entry's along its ancestry, else #f"
  (check-equal? #\\ (syntax:mode-escape chez-scheme:mode))
  (check-equal? #f (syntax:mode-escape modes:fundamental)))

(test "a deletion that leaves a string open, which then runs into the forms after, is not balanced"
  (let ([b (scheme-buffer "open.ss" "(a \"x\")\n(b)\n(c \"y\")\n")])
    (check-equal? #f (syntax:balanced? b (after b "\"x") (+ (after b "\"x") 1) ""))
    (check-equal? #t (syntax:balanced? b (before b "(b)") (after b "(b)") ""))))

(test "a replacement is balanced by the same rule: text that starts a lexeme running on is not, and text that moves a line comment's edge over balanced text is"
  (let ([b (scheme-buffer "replace.ss" "(f \"~a\")\n(g ; c\n(x)\n )\n")])
    (check-equal? #f (syntax:balanced? b (after b "~a") (after b "~a") "\\"))
    (check-equal? #t (syntax:balanced? b (after b "~a") (after b "~a") "\\n"))
    (check-equal? #t (syntax:balanced? b (after b "; c") (+ (after b "; c") 1) ""))
    (check-equal? #f (syntax:balanced? b (after b "(g ; c\n(x)\n") (+ (after b "(g ; c\n(x)\n") 1) "; "))))

(test "a bracket the inserted text touches must have its partner in the text, and one the range cuts must have its partner in the range"
  (let ([b (scheme-buffer "cut.ss" "(a b)\n#(c d)\n")])
    (check-equal? #f (syntax:balanced? b (before b "b)") (before b "b)") ")"))
    (check-equal? #t (syntax:balanced? b (before b "b)") (before b "b)") "()"))
    (check-equal? #f (syntax:balanced? b (after b "#") (after b "#(c d") ""))
    (check-equal? #t (syntax:balanced? b (after b "#") (after b "#(c d)") ""))))
