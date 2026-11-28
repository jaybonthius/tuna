(import (tuna) (test) (test-runner) (test-user) (hooks) (commands) (options) (tables) (buffers) (files) (auto-mode) (languages) (modes)
        (runs) (treesit) (treesit-install) (buffers-test) (treesit-test) (treesit-install-test))

(define home treesit-install-test:home)
(define vendored treesit-install-test:vendored)

(languages:define-grammar python (git vendored treesit-install-test:pinned))
(languages:define-grammar djot (file (string-append home "/nowhere/libtree-sitter-djot.so")))

(tables:define-table keymap "Keys.")
(hooks:define-hook hook "Setup.")
(modes:define-major-mode pyish (keymap keymap) (hook hook))
(modes:define-major-mode pyish2 (keymap keymap) (hook hook))
(modes:define-major-mode djotish (keymap keymap) (hook hook))

(languages:define-language "pyish" (mode pyish) (file-names "pyish") (grammar python))
(languages:define-language "pyish2" (mode pyish2) (grammar python))
(languages:define-language "djotish" (mode djotish) (grammar djot))

(define file (treesit:grammar-file python))

(test "a preview whose grammar is missing asks nothing"
  (treesit-test:write-file! (string-append home "/a.pyish") "x = 1\n")
  (let ([b (files:visit-temporarily (string-append home "/a.pyish"))])
    (test-user:settle)
    (check-equal? '() (treesit-install-test:take-asked!))
    (buffers:kill! b)))

(test "with when-missing never, a missing grammar is neither asked about nor built"
  (options:set! treesit-install:when-missing (treesit-install:missing never))
  (treesit-install-test:buffer-in pyish)
  (test-user:settle)
  (check-equal? '(() ()) (list (treesit-install-test:take-asked!) (treesit-install-test:take-told!)))
  (check-equal? #f (file-exists? file))
  (options:unset! treesit-install:when-missing))

(define b #f)

(test "a buffer whose grammar's file is missing is asked about, after it is made; no is not asked again this session, for any language of the grammar"
  (treesit-install-test:answer! #f)
  (set! b (treesit-install-test:buffer-in pyish))
  (check-equal? '() (treesit-install-test:take-asked!))
  (test-runner:wait-until treesit-install-test:asked?)
  (check-equal? (list (string-append "Install the tree-sitter grammar for python from " vendored "? "))
                (treesit-install-test:take-asked!))
  (treesit-install-test:buffer-in pyish)
  (treesit-install-test:buffer-in pyish2)
  (test-user:settle)
  (check-equal? '(() ()) (list (treesit-install-test:take-asked!) (treesit-install-test:take-told!)))
  (check-equal? #f (file-exists? file)))

(test "the command installs a language's grammar whatever was answered, in a run, and colours every buffer of the grammar"
  (treesit-install:grammar "pyish2")
  (treesit-install-test:wait-told "Installed the tree-sitter grammar for python")
  (check-equal? '("Installing the tree-sitter grammar for python…" "Installed the tree-sitter grammar for python")
                (treesit-install-test:take-told!))
  (check (file-exists? file))
  (check-equal? 0 (runs:status (buffers:find "*treesit-install python*")))
  (treesit-test:runs-become b treesit-install-test:coloured))

(test "the build leaves no scratch folder, no temporary file, and the source repository as it was"
  (check-equal? '() (directory-list (string-append home "/.cache/tuna/grammars")))
  (check-equal? (list (path-last file)) (directory-list (path-parent file)))
  (check-equal? treesit-install-test:pinned (treesit-install-test:run! "git" "-C" vendored "rev-parse" "HEAD"))
  (check-equal? "" (treesit-install-test:run! "git" "-C" vendored "status" "--porcelain")))

(test "the command raises for a language whose grammar is not built from source, or that has none"
  (check-raises (buffers-test:raised-with? 'treesit-install:grammar "no grammar built from source for the language" '("djotish"))
                (treesit-install:grammar "djotish"))
  (check-raises (buffers-test:raised-with? 'treesit-install:grammar "no grammar built from source for the language" '("nothing"))
                (treesit-install:grammar "nothing")))

(test "interactively, the command asks among the languages whose grammar is built from source"
  (let ([offered #f])
    (options:set! ask:choice-reader (lambda (question choices) (set! offered (list question (map car choices))) "pyish"))
    (commands:run treesit-install:grammar)
    (check-equal? '("Install the tree-sitter grammar of the language: " ("pyish" "pyish2")) offered)
    (treesit-install-test:wait-told "Installed the tree-sitter grammar for python")
    (treesit-install-test:take-told!)))

(test "a grammar named by its file is never asked about"
  (treesit-install-test:buffer-in djotish)
  (test-user:settle)
  (check-equal? '() (treesit-install-test:take-asked!)))
