(import (tuna) (test) (test-user) (makefile) (languages) (modes) (prog) (auto-mode) (syntax) (buffers) (document) (comment)
        (treesit-test) (sexp-test scene))

(define (in-makefile marked keys)
  (sexp-test/scene:show-in! makefile:mode marked)
  (test-user:press! keys)
  (sexp-test/scene:shown))

(test "makefile:mode derives from prog:mode, with the lighter Makefile, and edits the language makefile"
  (check-equal? (list makefile:mode prog:mode) (modes:ancestry makefile:mode))
  (check-equal? '("Makefile" "makefile") (list (modes:lighter makefile:mode) (languages:of makefile:mode))))

(test "the mode is chosen for Makefile, makefile, GNUmakefile and names ending .mk, .mak and .make, and for a #! line naming make"
  (let ([b (buffers:make (buffers:free-name "n") "")])
    (check-equal? (list makefile:mode makefile:mode makefile:mode makefile:mode makefile:mode makefile:mode #f)
                  (map (lambda (name) (auto-mode:by-file-name b name))
                       '("/p/Makefile" "/p/makefile" "/p/GNUmakefile" "/p/rules.mk" "/p/x.mak" "/p/x.make" "/p/Makefile.am"))))
  (check-equal? makefile:mode (auto-mode:by-interpreter (buffers:make (buffers:free-name "s") "#!/usr/bin/make -f\n") "s")))

(test "the grammar is tree-sitter-make at the revision nvim-treesitter's queries were written for"
  (let-values ([(url revision) (treesit-test:nvim-treesitter-pin "make")])
    (check-equal? (list "make" url revision)
                  (list (languages:grammar-name makefile:make) (languages:grammar-url makefile:make)
                        (languages:grammar-commit makefile:make)))))

(test "TAB inserts a tab at the cursor wherever it is on the line, and on a recipe line keeps the recipe's tab, as Emacs's makefile-mode"
  (check-equal? "all:\n\t|" (in-makefile "all:\n|" "TAB"))
  (check-equal? "all:\n\techo\t| hi" (in-makefile "all:\n\techo| hi" "TAB"))
  (check-equal? "all:\n\t\t|\techo hi" (in-makefile "all:\n\t|\techo hi" "TAB")))

(test "TAB with a prefix number inserts that many tabs, as Emacs's insert-tab takes TAB's argument"
  (check-equal? "all:\n\t\t|" (in-makefile "all:\n|" "M-2 TAB")))

(test "RET after a recipe line starts the new line at column 0, as Emacs's makefile-mode; TAB then gives it its tab"
  (check-equal? "all:\n\techo hi\n|" (in-makefile "all:\n\techo hi|" "RET"))
  (check-equal? "all:\n\techo hi\n\t|" (in-makefile "all:\n\techo hi|" "RET TAB")))

(test "M-; on an empty line writes the language's comment start, #"
  (check-equal? "all:\n# |" (in-makefile "all:\n|" "M-;")))
