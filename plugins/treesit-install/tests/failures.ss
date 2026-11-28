(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (tables) (buffers) (languages) (modes) (runs) (treesit)
        (treesit-install) (treesit-test) (treesit-install-test))

(define-values (generated generated-commit)
  (treesit-install-test:repository! "generated" '(("grammar.js" . "module.exports = {};\n"))))
(define-values (nested nested-commit)
  (treesit-install-test:repository! "nested" '(("inner/src/parser.c" . "int x;\n") ("grammar.js" . "module.exports = {};\n"))))
(define-values (cxx cxx-commit)
  (treesit-install-test:repository! "cxx" '(("src/parser.c" . "int x;\n") ("src/scanner.cc" . "int y;\n"))))

(languages:define-grammar python (git treesit-install-test:vendored treesit-install-test:pinned))
(languages:define-grammar swift (git generated generated-commit))
(languages:define-grammar cppish (git cxx cxx-commit))
(languages:define-grammar inner (git nested nested-commit "inner"))
(languages:define-grammar outer (git nested nested-commit))
(languages:define-grammar broken (git treesit-install-test:vendored "0000000000000000000000000000000000000000"))

(tables:define-table keymap "Keys.")
(hooks:define-hook hook "Setup.")
(modes:define-major-mode pyish (keymap keymap) (hook hook))
(modes:define-major-mode swiftish (keymap keymap) (hook hook))
(modes:define-major-mode cppish-mode (keymap keymap) (hook hook))
(modes:define-major-mode brokenish (keymap keymap) (hook hook))

(languages:define-language "pyish" (mode pyish) (grammar python))
(languages:define-language "swiftish" (mode swiftish) (grammar swift))
(languages:define-language "cppish" (mode cppish-mode) (grammar cppish))
(languages:define-language "brokenish" (mode brokenish) (grammar broken))
(languages:define-language "innerish" (grammar inner))
(languages:define-language "outerish" (grammar outer))

(define path (getenv "PATH"))
(define no-git (treesit-install-test:path-of! "no-git" '("cc")))
(define no-cc (treesit-install-test:path-of! "no-cc" '("git")))
(define no-cxx (treesit-install-test:path-of! "no-cxx" '("git" "cc" "rm" "mkdir")))

(test "git and a C compiler are checked first, and their lack told; nothing is built"
  (putenv "PATH" no-git)
  (treesit-install:grammar "pyish")
  (putenv "PATH" no-cc)
  (treesit-install:grammar "pyish")
  (putenv "PATH" path)
  (check-equal? '("Installing the tree-sitter grammar for python needs git, which is not on the PATH"
                  "Installing the tree-sitter grammar for python needs a C compiler: cc, gcc or c99")
                (treesit-install-test:take-told!))
  (check-equal? '(#f #f) (list (file-exists? (treesit:grammar-file python)) (buffers:find "*treesit-install python*"))))

(test "a repository with no src/parser.c is told to be generated, and not asked about again"
  (treesit-install-test:buffer-in swiftish)
  (treesit-install-test:wait-told
    "The tree-sitter grammar for swift must be generated, which needs the tree-sitter program; build it yourself and name its file with a (file …) grammar")
  (check-equal? (list (string-append "Install the tree-sitter grammar for swift from " generated "? ")) (treesit-install-test:take-asked!))
  (check-equal? #f (file-exists? (treesit:grammar-file swift)))
  (treesit-install-test:buffer-in swiftish)
  (test-user:settle)
  (check-equal? '() (treesit-install-test:take-asked!))
  (treesit-install-test:take-told!))

(test "a C++ scanner with no C++ compiler on the PATH stops the build, which tells so"
  (putenv "PATH" no-cxx)
  (treesit-install:grammar "cppish")
  (treesit-install-test:wait-told "Installing the tree-sitter grammar for cppish needs a C++ compiler: c++ or g++")
  (putenv "PATH" path)
  (check-equal? #f (file-exists? (treesit:grammar-file cppish)))
  (treesit-install-test:take-told!))

(test "a build that fails is told, its run kept to read, and its grammar not asked about again"
  (treesit-install-test:buffer-in brokenish)
  (treesit-install-test:wait-told "Installing the tree-sitter grammar for broken failed; see *treesit-install broken*")
  (check-equal? 1 (length (treesit-install-test:take-asked!)))
  (check (not (eqv? 0 (runs:status (buffers:find "*treesit-install broken*")))))
  (treesit-install-test:take-told!)
  (treesit-install-test:buffer-in brokenish)
  (test-user:settle)
  (check-equal? '() (treesit-install-test:take-asked!)))

(test "a grammar whose parser is in a folder of its repository is built from that folder; the same repository from its root must be generated"
  (treesit-install:grammar "innerish")
  (treesit-install-test:wait-told "Installed the tree-sitter grammar for inner")
  (check (file-exists? (treesit:grammar-file inner)))
  (treesit-install:grammar "outerish")
  (treesit-install-test:wait-told
    "The tree-sitter grammar for outer must be generated, which needs the tree-sitter program; build it yourself and name its file with a (file …) grammar")
  (check-equal? #f (file-exists? (treesit:grammar-file outer)))
  (treesit-install-test:take-told!))
