(import (tuna) (test) (test-user) (dotenv) (sh-script) (languages) (modes) (prog) (auto-mode) (syntax) (buffers) (document) (tables)
        (comment) (sexp-test scene))

(define (lexemes text)
  (map (lambda (l) (list (syntax:lexeme-class l) (document:text (document:from-datum text) (syntax:lexeme-start l) (syntax:lexeme-end l))))
       (vector->list ((syntax:lexer dotenv:mode) (document:from-datum text)))))

(test "dotenv:mode derives from prog:mode, with the lighter Env, and edits the language dotenv"
  (check-equal? (list dotenv:mode prog:mode) (modes:ancestry dotenv:mode))
  (check-equal? '("Env" "dotenv") (list (modes:lighter dotenv:mode) (languages:of dotenv:mode))))

(test "the mode is chosen for .env and .env followed by a dot and anything; .envrc is shell"
  (let ([b (buffers:make (buffers:free-name "n") "")])
    (check-equal? (list dotenv:mode dotenv:mode dotenv:mode sh-script:mode #f)
                  (map (lambda (name) (auto-mode:by-file-name b name))
                       '("/p/.env" "/p/.env.example" "/p/.env.local" "/p/.envrc" "/p/env")))))

(test "its grammar is sh-script's bash, one grammar for both languages"
  (check (eq? sh-script:bash (tables:ref languages:grammar "dotenv" #f)))
  (check (eq? (tables:ref languages:grammar "shellscript" #f) (tables:ref languages:grammar "dotenv" #f))))

(test "a # starts a comment at a line's start or after a blank, not inside a value; quotes make strings"
  (check-equal? '((comment "# key") (atom "A=1") (comment "# note") (atom "URL=http://x#frag") (atom "B=") (string "\"a # b\""))
                (lexemes "# key\nA=1 # note\nURL=http://x#frag\nB=\"a # b\"")))

(test "M-; writes a # comment"
  (sexp-test/scene:show-in! dotenv:mode "A=1\n|")
  (test-user:press! "M-;")
  (check-equal? "A=1\n# |" (sexp-test/scene:shown)))
