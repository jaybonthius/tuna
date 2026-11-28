(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (tables) (buffers) (languages) (modes) (treesit)
        (treesit-install) (treesit-test) (treesit-install-test))

(languages:define-grammar python (git treesit-install-test:vendored treesit-install-test:pinned))

(tables:define-table keymap "Keys.")
(hooks:define-hook hook "Setup.")
(modes:define-major-mode pyish (keymap keymap) (hook hook))
(languages:define-language "pyish" (mode pyish) (grammar python))

(test "with when-missing always, a missing grammar is built with no question"
  (options:set! treesit-install:when-missing (treesit-install:missing always))
  (let ([b (treesit-install-test:buffer-in pyish)])
    (treesit-install-test:wait-told "Installed the tree-sitter grammar for python")
    (check-equal? '() (treesit-install-test:take-asked!))
    (check (file-exists? (treesit:grammar-file python)))
    (treesit-test:runs-become b treesit-install-test:coloured)))

(test "when-missing takes only ask, always and never"
  (check-raises assertion-violation? (options:set! treesit-install:when-missing 'sometimes)))
