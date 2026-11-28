(import (tuna) (test) (test-user) (dockerfile) (languages) (modes) (prog) (auto-mode) (syntax) (buffers) (document) (comment)
        (treesit-test) (sexp-test scene))

(define (lexemes text)
  (map (lambda (l) (list (syntax:lexeme-class l) (document:text (document:from-datum text) (syntax:lexeme-start l) (syntax:lexeme-end l))))
       (vector->list ((syntax:lexer dockerfile:mode) (document:from-datum text)))))

(test "dockerfile:mode derives from prog:mode, with the lighter Dockerfile, and edits the language dockerfile"
  (check-equal? (list dockerfile:mode prog:mode) (modes:ancestry dockerfile:mode))
  (check-equal? '("Dockerfile" "dockerfile") (list (modes:lighter dockerfile:mode) (languages:of dockerfile:mode))))

(test "the mode is chosen for Dockerfile and Containerfile, either followed by a dot and anything, and names ending .dockerfile"
  (let ([b (buffers:make (buffers:free-name "n") "")])
    (check-equal? (list dockerfile:mode dockerfile:mode dockerfile:mode dockerfile:mode dockerfile:mode #f)
                  (map (lambda (name) (auto-mode:by-file-name b name))
                       '("/p/Dockerfile" "/p/Dockerfile.dev" "/p/Containerfile" "/p/Containerfile.ci" "/p/x.dockerfile"
                         "/p/MyDockerfile.x")))))

(test "the grammar is tree-sitter-dockerfile at the revision nvim-treesitter's queries were written for"
  (let-values ([(url revision) (treesit-test:nvim-treesitter-pin "dockerfile")])
    (check-equal? (list "dockerfile" url revision)
                  (list (languages:grammar-name dockerfile:dockerfile) (languages:grammar-url dockerfile:dockerfile)
                        (languages:grammar-commit dockerfile:dockerfile)))))

(test "a # at a line's start is a comment; the exec form's brackets nest"
  (check-equal? '((comment "# base") (atom "FROM") (atom "x") (atom "CMD") (open "[") (string "\"a\"") (atom ",") (string "\"b\"") (close "]"))
                (lexemes "# base\nFROM x\nCMD [\"a\", \"b\"]")))

(test "M-; writes a # comment"
  (sexp-test/scene:show-in! dockerfile:mode "FROM x\n|")
  (test-user:press! "M-;")
  (check-equal? "FROM x\n# |" (sexp-test/scene:shown)))
