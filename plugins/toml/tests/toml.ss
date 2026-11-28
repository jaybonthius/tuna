(import (tuna) (test) (test-user) (toml) (languages) (modes) (prog) (auto-mode) (syntax) (buffers) (document) (comment)
        (treesit-test) (sexp-test scene))

(define (lexemes text)
  (map (lambda (l) (list (syntax:lexeme-class l) (document:text (document:from-datum text) (syntax:lexeme-start l) (syntax:lexeme-end l))))
       (vector->list ((syntax:lexer toml:mode) (document:from-datum text)))))

(test "toml:mode derives from prog:mode, with the lighter TOML, and edits the language toml"
  (check-equal? (list toml:mode prog:mode) (modes:ancestry toml:mode))
  (check-equal? '("TOML" "toml") (list (modes:lighter toml:mode) (languages:of toml:mode))))

(test "the mode is chosen for names ending .toml and for the lock files written in TOML"
  (let ([b (buffers:make (buffers:free-name "n") "")])
    (check-equal? (make-list 4 toml:mode)
                  (map (lambda (name) (auto-mode:by-file-name b name)) '("/p/pyproject.toml" "/p/Cargo.lock" "/p/uv.lock" "/p/Pipfile")))))

(test "the grammar is tree-sitter-toml at the revision nvim-treesitter's queries were written for"
  (let-values ([(url revision) (treesit-test:nvim-treesitter-pin "toml")])
    (check-equal? (list "toml" url revision)
                  (list (languages:grammar-name toml:toml) (languages:grammar-url toml:toml) (languages:grammar-commit toml:toml)))))

(test "a triple-quoted string runs over lines and holds single quotes and #; a literal string takes no escape"
  (check-equal? '((atom "a") (atom "=") (string "\"\"\"x \" # y\nz\"\"\"") (comment "# c"))
                (lexemes "a = \"\"\"x \" # y\nz\"\"\" # c"))
  (check-equal? '((atom "p") (atom "=") (string "'C:\\'") (atom "q")) (lexemes "p = 'C:\\' q")))

(test "M-; writes a # comment"
  (sexp-test/scene:show-in! toml:mode "[a]\n|")
  (test-user:press! "M-;")
  (check-equal? "[a]\n# |" (sexp-test/scene:shown)))
