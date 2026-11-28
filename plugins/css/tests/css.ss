(import (tuna) (test) (test-user) (css) (languages) (modes) (prog) (auto-mode) (syntax) (buffers) (document) (comment)
        (treesit-test) (syntax-test) (sexp-test scene))

(define (lexemes text)
  (map (lambda (l) (list (syntax:lexeme-class l) (document:text (document:from-datum text) (syntax:lexeme-start l) (syntax:lexeme-end l))
                         (syntax:lexeme-open-ended? l)))
       (vector->list ((syntax:lexer css:mode) (document:from-datum text)))))

(test "css:mode derives from prog:mode, with the lighter CSS, and edits the language css"
  (check-equal? (list css:mode prog:mode) (modes:ancestry css:mode))
  (check-equal? '("CSS" "css") (list (modes:lighter css:mode) (languages:of css:mode))))

(test "the mode is chosen for names ending .css"
  (check-equal? css:mode (auto-mode:by-file-name (buffers:make (buffers:free-name "n") "") "/p/site.css")))

(test "the grammar is tree-sitter-css at the revision nvim-treesitter's queries were written for"
  (let-values ([(url revision) (treesit-test:nvim-treesitter-pin "css")])
    (check-equal? (list "css" url revision)
                  (list (languages:grammar-name css:css) (languages:grammar-url css:css) (languages:grammar-commit css:css)))))

(test "a block comment left open runs to the end of the text; one closed ends at its */"
  (check-equal? '((atom "a" #f) (open "{" #f) (atom "color:" #f) (atom "red" #f) (close "}" #f) (comment "/* c" #t))
                (lexemes "a { color: red } /* c"))
  (check-equal? '((comment "/* a\nb */" #f) (atom "p" #f)) (lexemes "/* a\nb */ p")))

(test "M-; writes a /* */ comment, the cursor between its ends"
  (sexp-test/scene:show-in! css:mode "a {}\n|")
  (test-user:press! "M-;")
  (check-equal? "a {}\n/* | */" (sexp-test/scene:shown)))

(test "symbols hold - and _, so the symbol at point is a whole property"
  (let ([b (buffers:make (buffers:free-name "s.css") "a { font-family: x }")])
    (modes:set-major-mode css:mode b)
    (check-equal? "font-family"
                  (call-with-values (lambda () (syntax:symbol-bounds b (syntax-test:after b "font-f")))
                    (lambda (s e) (syntax-test:between b s e))))))
