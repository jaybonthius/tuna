(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (tables) (buffers) (languages) (modes) (treesit)
        (treesit-install) (treesit-test) (treesit-install-test))

(languages:define-grammar python (git treesit-install-test:vendored treesit-install-test:pinned))

(tables:define-table keymap "Keys.")
(hooks:define-hook hook "Setup.")
(modes:define-major-mode pyish (keymap keymap) (hook hook))
(languages:define-language "pyish" (mode pyish) (grammar python))

(define file (treesit:grammar-file python))
(define old (string-append (path-parent file) "/libtree-sitter-python-000000000000.so"))

(treesit-test:write-file! old "an older commit's grammar\n")

(test "another commit's file of the grammar makes the question an update; a second buffer meanwhile asks nothing; the old file goes once the build succeeds"
  (let ([b (treesit-install-test:buffer-in pyish)])
    (test-runner:wait-until treesit-install-test:asked?)
    (treesit-install-test:buffer-in pyish)
    (treesit-install-test:wait-told "Installed the tree-sitter grammar for python")
    (check-equal? (list (string-append "Update the tree-sitter grammar for python from " treesit-install-test:vendored "? "))
                  (treesit-install-test:take-asked!))
    (check-equal? '(#f #t) (list (file-exists? old) (file-exists? file)))
    (treesit-test:runs-become b treesit-install-test:coloured)))
