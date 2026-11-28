(import (tuna) (test) (test-user) (json-language) (languages) (modes) (prog) (auto-mode) (syntax) (buffers) (document) (tables)
        (editing) (comment-syntax) (treesit-test) (syntax-test) (sexp-test scene))

(define (in-json marked keys)
  (sexp-test/scene:show-in! json-language:mode marked)
  (test-user:press! keys)
  (sexp-test/scene:shown))

(define (lexemes mode text)
  (map (lambda (l) (list (syntax:lexeme-class l) (document:text (document:from-datum text) (syntax:lexeme-start l) (syntax:lexeme-end l))
                         (syntax:lexeme-depth l)))
       (vector->list ((syntax:lexer mode) (document:from-datum text)))))

(test "json-language:mode edits JSON and its child jsonc-mode JSON with comments, sharing one grammar"
  (check-equal? (list json-language:mode prog:mode) (modes:ancestry json-language:mode))
  (check-equal? (list json-language:jsonc-mode json-language:mode prog:mode) (modes:ancestry json-language:jsonc-mode))
  (check-equal? '("JSON" "json" "JSONC" "jsonc")
                (list (modes:lighter json-language:mode) (languages:of json-language:mode)
                      (modes:lighter json-language:jsonc-mode) (languages:of json-language:jsonc-mode)))
  (check (eq? (tables:ref languages:grammar "json" #f) (tables:ref languages:grammar "jsonc" #f))))

(test "names ending .json choose JSON; .jsonc and the configuration files that hold comments choose JSON with comments, their whole name beating .json"
  (let ([b (buffers:make (buffers:free-name "n") "")])
    (check-equal? (list json-language:mode json-language:mode json-language:mode
                        json-language:jsonc-mode json-language:jsonc-mode json-language:jsonc-mode)
                  (map (lambda (name) (auto-mode:by-file-name b name))
                       '("/p/package.json" "/p/x.geojson" "/p/site.webmanifest"
                         "/p/x.jsonc" "/p/tsconfig.json" "/p/.devcontainer/devcontainer.json")))))

(test "the grammar is tree-sitter-json at the revision nvim-treesitter's queries were written for"
  (let-values ([(url revision) (treesit-test:nvim-treesitter-pin "json")])
    (check-equal? (list "json" url revision)
                  (list (languages:grammar-name json-language:json) (languages:grammar-url json-language:json)
                        (languages:grammar-commit json-language:json)))))

(test "brackets give depth; a string takes escapes and ends at its line's end when unclosed"
  (check-equal? '((open "{" 1) (string "\"a\"" 1) (atom ":" 1) (string "\"x\\\"y\"" 1) (close "}" 1))
                (lexemes json-language:mode "{\"a\": \"x\\\"y\"}"))
  (check-equal? '((open "[" 1) (string "\"ab" 1) (close "]" 1)) (lexemes json-language:mode "[\"ab\n]")))

(test "JSON has no comments, so // is text and M-; has nothing to write; JSON with comments has // and /* */"
  (check-equal? '((atom "//" 0) (atom "x" 0)) (lexemes json-language:mode "// x"))
  (check-equal? '((comment "// x" 0) (comment "/* y */" 0)) (lexemes json-language:jsonc-mode "// x\n/* y */"))
  (let ([j (buffers:make (buffers:free-name "j") "")] [c (buffers:make (buffers:free-name "c") "")])
    (modes:set-major-mode json-language:mode j)
    (modes:set-major-mode json-language:jsonc-mode c)
    (check-equal? '((#f "") ("//" ""))
                  (map (lambda (b) (call-with-values (lambda () (comment-syntax:delimiters b)) list)) (list j c)))))

(test "RET gives the new line the indentation of the line above; TAB adds blanks to the next indent point above, taking none away"
  (check-equal? "{\n  \"a\": 1,\n  |" (in-json "{\n  \"a\": 1,|" "RET"))
  (check-equal? "{\n  \"a\": {\n  |" (in-json "{\n  \"a\": {|" "RET"))
  (check-equal? "{\n  \"a\": {\n       |" (in-json "{\n  \"a\": {|" "RET TAB"))
  (check-equal? "{\n  \"a\": {\n        |" (in-json "{\n  \"a\": {|" "RET TAB TAB"))
  (check-equal? "{\n  \"a\": [\n       |1" (in-json "{\n  \"a\": [\n    |1" "TAB")))

(test "the questions answer from the lexemes: the sexp after a key's value, and the lists around a position"
  (let ([b (buffers:make (buffers:free-name "q.json") "{\"a\": [1, {\"b\": 2}]}")])
    (modes:set-major-mode json-language:mode b)
    (check-equal? (syntax-test:after b "{\"b\": 2}") (syntax:sexp-after b (syntax-test:before b "{\"b\"")))
    (check-equal? 3 (length (syntax:openings b (syntax-test:after b "\"b"))))))
