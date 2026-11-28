(import (tuna) (test) (test-user) (yaml) (languages) (modes) (prog) (auto-mode) (syntax) (buffers) (document) (comment)
        (treesit-test) (sexp-test scene))

(define (in-yaml marked keys)
  (sexp-test/scene:show-in! yaml:mode marked)
  (test-user:press! keys)
  (sexp-test/scene:shown))

(define (lexemes text)
  (map (lambda (l) (list (syntax:lexeme-class l) (document:text (document:from-datum text) (syntax:lexeme-start l) (syntax:lexeme-end l))))
       (vector->list ((syntax:lexer yaml:mode) (document:from-datum text)))))

(test "yaml:mode derives from prog:mode, with the lighter YAML, and edits the language yaml"
  (check-equal? (list yaml:mode prog:mode) (modes:ancestry yaml:mode))
  (check-equal? '("YAML" "yaml") (list (modes:lighter yaml:mode) (languages:of yaml:mode))))

(test "the mode is chosen for names ending .yml and .yaml"
  (let ([b (buffers:make (buffers:free-name "n") "")])
    (check-equal? (list yaml:mode yaml:mode yaml:mode)
                  (map (lambda (name) (auto-mode:by-file-name b name)) '("/p/ci.yml" "/p/x.yaml" "/p/.clang-format")))))

(test "the grammar is tree-sitter-yaml at the revision nvim-treesitter's queries were written for"
  (let-values ([(url revision) (treesit-test:nvim-treesitter-pin "yaml")])
    (check-equal? (list "yaml" url revision)
                  (list (languages:grammar-name yaml:yaml) (languages:grammar-url yaml:yaml) (languages:grammar-commit yaml:yaml)))))

(test "an apostrophe inside a word opens no string, and a # inside a value is no comment"
  (check-equal? '((atom "a:") (atom "it's") (atom "fine") (comment "# c")) (lexemes "a: it's fine # c"))
  (check-equal? '((atom "url:") (atom "http://x#y") (atom "b:") (string "'q # r'")) (lexemes "url: http://x#y\nb: 'q # r'")))

(test "RET gives the new line the indentation of the line above; TAB adds blanks to the next indent point above, or the next tab stop, and never pulls a nested line left"
  (check-equal? "a:\n  b: 1\n  |" (in-yaml "a:\n  b: 1|" "RET"))
  (check-equal? "a:\n        |" (in-yaml "a:\n|" "TAB"))
  (check-equal? "a:\n  b: 1\n  |c: 2" (in-yaml "a:\n  b: 1\n|c: 2" "TAB"))
  (check-equal? "a:\n  b:\n    c: 1\n    |" (in-yaml "a:\n  b:\n    c: 1|" "RET"))
  (check-equal? "a:\n  b:\n  |    c: 1" (in-yaml "a:\n  b:\n|    c: 1" "TAB")))

(test "M-; writes a # comment"
  (check-equal? "a: 1\n# |" (in-yaml "a: 1\n|" "M-;")))
