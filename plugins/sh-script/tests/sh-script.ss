(import (tuna) (test) (test-user) (sh-script) (languages) (modes) (prog) (auto-mode) (syntax) (buffers) (document) (comment)
        (treesit-test) (syntax-test) (sexp-test scene))

(define (in-shell marked keys)
  (sexp-test/scene:show-in! sh-script:mode marked)
  (test-user:press! keys)
  (sexp-test/scene:shown))

(define (lexemes text)
  (map (lambda (l) (list (syntax:lexeme-class l) (document:text (document:from-datum text) (syntax:lexeme-start l) (syntax:lexeme-end l))))
       (vector->list ((syntax:lexer sh-script:mode) (document:from-datum text)))))

(test "sh-script:mode derives from prog:mode, with the lighter Shell, and edits the language shellscript"
  (check-equal? (list sh-script:mode prog:mode) (modes:ancestry sh-script:mode))
  (check-equal? '("Shell" "shellscript") (list (modes:lighter sh-script:mode) (languages:of sh-script:mode))))

(test "the mode is chosen for names ending .sh, .bash, .zsh and .ksh, the shells' startup files, and a #! line naming sh, bash, dash, zsh or ksh"
  (let ([b (buffers:make (buffers:free-name "n") "")])
    (check-equal? (make-list 10 sh-script:mode)
                  (map (lambda (name) (auto-mode:by-file-name b name))
                       '("/p/a.sh" "/p/a.bash" "/p/a.zsh" "/p/a.ksh" "/h/.bashrc" "/h/.bash_profile" "/h/.profile" "/h/.zshrc"
                         "/p/.envrc" "/p/PKGBUILD"))))
  (check-equal? (make-list 6 sh-script:mode)
                (map (lambda (line) (auto-mode:by-interpreter (buffers:make (buffers:free-name "s") line) "s"))
                     '("#!/bin/sh\n" "#!/usr/bin/env bash\n" "#!/bin/dash\n" "#!/bin/zsh\n" "#!/bin/ksh\n" "#!/bin/bash5.2\n"))))

(test "the grammar is tree-sitter-bash at the revision nvim-treesitter's queries were written for"
  (let-values ([(url revision) (treesit-test:nvim-treesitter-pin "bash")])
    (check-equal? (list "bash" url revision)
                  (list (languages:grammar-name sh-script:bash) (languages:grammar-url sh-script:bash)
                        (languages:grammar-commit sh-script:bash)))))

(test "a # in a string is no comment, a # after code is, and a # inside a word is none"
  (check-equal? '((atom "echo") (string "\"a # b\"") (comment "# c")) (lexemes "echo \"a # b\" # c"))
  (check-equal? '((atom "echo") (atom "a#b")) (lexemes "echo a#b")))

(test "a single-quoted string takes no escape; a double-quoted one does"
  (check-equal? '((string "'a\\'") (atom "b") (string "'")) (lexemes "'a\\' b'"))
  (check-equal? '((string "\"a\\\" b\"")) (lexemes "\"a\\\" b\"")))

(test "M-; writes a # comment, and show-paren's brackets are the language's"
  (check-equal? "x\n# |" (in-shell "x\n|" "M-;"))
  (check-equal? '((#\( . #\)) (#\[ . #\]) (#\{ . #\})) (syntax:mode-bracket-pairs sh-script:mode)))

(test "symbols hold _, - and ., so the symbol at point is a whole option or file name"
  (let ([b (buffers:make (buffers:free-name "s.sh") "ls --all-files my_file.txt")])
    (modes:set-major-mode sh-script:mode b)
    (check-equal? '("--all-files" "my_file.txt")
                  (map (lambda (p) (call-with-values (lambda () (syntax:symbol-bounds b p))
                                     (lambda (s e) (syntax-test:between b s e))))
                       (list (syntax-test:after b "--al") (syntax-test:after b "my_f"))))))
