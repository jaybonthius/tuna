(import (tuna) (test) (lexer-check) (chez-scheme lexer))

(define (lexemes text)
  (map (lambda (t) (list (lexeme-kind t) (substring text (lexeme-start t) (lexeme-end t)) (lexeme-depth t)))
       (vector->list (lex text))))

(test "for every token Chez's read-token returns in Tuna's own plugins, the lexer gives the same start, end and kind, and #; with its datum ends where the reader's datum ends"
  (let-values ([(files tokens disagreements)
                (check-files (scheme-files (string-append (path-parent (car (command-line))) "/plugins")))])
    (check (> files 50))
    (check (> tokens 100000))
    (check-equal? '() disagreements)))

(test "each kind of opening, with its depth"
  (check-equal? '((open "(" 1) (open "[" 2) (open "#(" 3) (open "#[" 4) (open "#vu8(" 5) (open "#vfx(" 6) (open "#vfl(" 7)
                  (open "#vs(" 8) (open "#3(" 9) (open "#3vfx(" 10) (close "]" 10) (close ")" 9) (close ")" 8) (close ")" 7)
                  (close ")" 6) (close ")" 5) (close ")" 4) (close ")" 3) (close ")" 2) (close ")" 1))
                (lexemes "( [ #( #[ #vu8( #vfx( #vfl( #vs( #3( #3vfx( ] ) ) ) ) ) ) ) ) )")))

(test "prefixes and labels"
  (check-equal? '((prefix "'" 0) (symbol "a" 0) (prefix "`" 0) (symbol "a" 0) (prefix "," 0) (symbol "a" 0) (prefix ",@" 0)
                  (symbol "a" 0) (prefix "#'" 0) (symbol "a" 0) (prefix "#`" 0) (symbol "a" 0) (prefix "#," 0) (symbol "a" 0)
                  (prefix "#,@" 0) (symbol "a" 0) (prefix "#&" 0) (symbol "a" 0) (prefix "#0=" 0) (symbol "a" 0))
                (lexemes "'a `a ,a ,@a #'a #`a #,a #,@a #&a #0=a")))

(test "symbols"
  (check-equal? '((symbol "list->vector" 0) (symbol "buffers:make" 0) (symbol "|two words|" 0) (symbol "#%car" 0)
                  (symbol "#3%car" 0) (symbol "#:g0" 0) (symbol "#{g0 x}" 0) (symbol "a\\x41;b" 0) (symbol "->" 0)
                  (symbol "..." 0) (symbol ".." 0) (symbol "-" 0) (symbol "+" 0) (symbol "{" 0))
                (lexemes "list->vector buffers:make |two words| #%car #3%car #:g0 #{g0 x} a\\x41;b -> ... .. - + {")))

(test "numbers, booleans, characters and the dot"
  (check-equal? '((number "42" 0) (number "#x1F" 0) (number "1/2" 0) (number "+inf.0" 0) (number "-1.5e3" 0) (number "#e1.5" 0)
                  (number "#36rZZ" 0) (number ".5" 0) (symbol "1+" 0) (boolean "#t" 0) (boolean "#false" 0)
                  (character "#\\a" 0) (character "#\\space" 0) (character "#\\x3bb" 0) (character "#\\(" 0) (open "(" 1)
                  (symbol "a" 1) (dot "." 1) (symbol "b" 1) (close ")" 1))
                (lexemes "42 #x1F 1/2 +inf.0 -1.5e3 #e1.5 #36rZZ .5 1+ #t #false #\\a #\\space #\\x3bb #\\( (a . b)")))

(test "objects, strings, comments and directives"
  (check-equal? '((object "#!eof" 0) (object "#!bwp" 0) (object "#!base-rtd" 0) (object "#@" 0) (object "#0#" 0)
                  (string "\"a \\\"b\\\"\"" 0) (line-comment "; note" 0) (block-comment "#| a #| b |# c |#" 0)
                  (datum-comment "#;(f x)" 0) (directive "#!r6rs" 0) (directive "#!chezscheme" 0) (directive "#!fold-case" 0)
                  (directive "#!no-fold-case" 0) (directive "#!tuna" 0))
                (lexemes "#!eof #!bwp #!base-rtd #@ #0# \"a \\\"b\\\"\" ; note\n#| a #| b |# c |# #;(f x) #!r6rs #!chezscheme #!fold-case #!no-fold-case #!tuna")))

(test "a first line starting #! and a space or slash is one directive; the four directives Chez knows need no delimiter after them"
  (check-equal? '((directive "#!/usr/bin/env scheme-script" 0) (open "(" 1) (symbol "display" 1) (number "1" 1) (close ")" 1))
                (lexemes "#!/usr/bin/env scheme-script\n(display 1)"))
  (check-equal? '((directive "#!r6rs" 0) (open "(" 1) (symbol "a" 1) (close ")" 1)) (lexemes "#!r6rs(a)")))

(test "after #!r6rs a number ends at #, as the reader's r6rs mode ends it; #!chezscheme turns that off"
  (check-equal? '((symbol "1#2" 0) (directive "#!r6rs" 0) (number "1" 0) (symbol "#2" 0) (directive "#!chezscheme" 0) (symbol "1#2" 0))
                (lexemes "1#2 #!r6rs 1#2 #!chezscheme 1#2")))

(test "#; and its datum are one comment, prefixes and comments before the datum included; a nested #; skips its own datum first; before a closing bracket it ends there"
  (check-equal? '((open "(" 1) (symbol "f" 1) (datum-comment "#;(g \"x\" 1)" 1) (number "2" 1) (close ")" 1))
                (lexemes "(f #;(g \"x\" 1) 2)"))
  (check-equal? '((datum-comment "#; #; a b" 0) (symbol "c" 0)) (lexemes "#; #; a b c"))
  (check-equal? '((datum-comment "#; ; note\n '(x)" 0) (symbol "y" 0)) (lexemes "#; ; note\n '(x) y"))
  (check-equal? '((open "(" 1) (datum-comment "#;" 1) (close ")" 1) (symbol "a" 0)) (lexemes "(#; ) a")))

(test "a line comment is always open-ended, and so is a string, block comment, |symbol| or datum comment the text leaves open"
  (define (open-ended text)
    (map (lambda (t) (list (lexeme-kind t) (lexeme-open-ended? t))) (vector->list (lex text))))
  (check-equal? '((line-comment #t)) (open-ended "; a\n"))
  (check-equal? '((symbol #f) (string #t)) (open-ended "x \"abc"))
  (check-equal? '((block-comment #t)) (open-ended "#| a #| b |#"))
  (check-equal? '((symbol #t)) (open-ended "|ab c"))
  (check-equal? '((datum-comment #t)) (open-ended "#;(f x")))

(test "depth counts from the start; a closing bracket of another shape than its opening is mismatched, and one with no opening has depth 0"
  (check-equal? '(("(" 1 #f) ("]" 1 #t) ("[" 1 #f) (")" 1 #t) ("#[" 1 #f) (")" 1 #t) ("(" 1 #f) (")" 1 #f) (")" 0 #f) (")" 0 #f))
                (let ([text "(a] [b) #[c) (d)) e)"])
                  (map (lambda (t) (list (substring text (lexeme-start t) (lexeme-end t)) (lexeme-depth t) (lexeme-mismatched? t)))
                       (filter (lambda (t) (memq (lexeme-kind t) '(open close))) (vector->list (lex text)))))))

(test "the lexer never raises: every prefix of a text of every kind lexes"
  (let ([sample "#!tuna\n(define (f x) \"s\\n\" #\\x3bb; #| c |# #;(g) '(a . b) #vu8(1 2) |q r| #{g0 x} #!eof #0=(1 . #0#))"])
    (check (for-all (lambda (n) (vector? (lex (substring sample 0 n)))) (iota (+ (string-length sample) 1)))))
  (check-equal? '(0 1 1 1 1 1 1 1 1 1 1 1)
                (map (lambda (text) (vector-length (lex text))) '("" "#" "#\\" "#!" "#v" "#3" "#{" "\\" "|" "#;" "#|" "\"\\"))))
