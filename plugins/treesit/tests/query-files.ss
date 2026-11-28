(import (tuna) (test) (tables) (options) (languages) (treesit) (python) (treesit highlight) (treesit-test) (treesit-test grammar) (treesit-test session))

(define python python:python)
(define grammar (treesit:grammar-file python))
(treesit-test/grammar:build-python! (languages:grammar-commit python) grammar)

(define excluded (options:default treesit:excluded-captures))

(define shipped-folders treesit-test/session:shipped-folders)
(define python-file (string-append (car shipped-folders) "/python/highlights.scm"))
(define nvim-file (string-append (cadr shipped-folders) "/python/highlights.scm"))

(define user (treesit-test:home-file ".config/tuna/queries"))
(define user-file (string-append user "/python/highlights.scm"))

(define (files) (query-files (cons user shipped-folders) "python" "highlights"))

(define (session text)
  (let ([s (treesit-test/session:open grammar text (files) excluded)])
    (treesit-test/session:settle! s)
    s))

(define (folder name) (treesit-test:home-file name))

(test "with no file of the user's, Python's highlights are nvim-treesitter's file, then the python plugin's, which extends it"
  (check-equal? (list nvim-file python-file) (treesit-test/session:shipped)))

(test "a user's file starting ; extends comes after both, so its patterns win"
  (treesit-test:write-file! user-file "; extends\n((identifier) @keyword.debug (#eq? @keyword.debug \"breakpoint\"))\n")
  (check-equal? (list nvim-file python-file user-file) (files))
  (check-equal? '(("breakpoint" keyword.debug) ("print" function.builtin))
                (treesit-test/session:runs (session "breakpoint()\nprint()\n"))))

(test "a user's file without ; extends replaces nvim-treesitter's, and the python plugin's still extends it"
  (treesit-test:write-file! user-file "((identifier) @keyword.debug (#eq? @keyword.debug \"breakpoint\"))\n")
  (check-equal? (list user-file python-file) (files))
  (check-equal? '(("breakpoint" keyword.debug)) (treesit-test/session:runs (session "breakpoint\n1\n"))))

(test "leading comment lines are read for ; inherits: and ; extends: a language inherits the files of each it names, whole, from the same folders, before its own; one in parentheses only when the file is not itself inherited; naming itself is extending"
  (treesit-test:write-file! (folder "a/base/highlights.scm") "; inherits: core\n(base)\n")
  (treesit-test:write-file! (folder "a/core/highlights.scm") "(core)\n")
  (treesit-test:write-file! (folder "b/core/highlights.scm") ";; extends\n(core extended)\n")
  (treesit-test:write-file! (folder "a/top/highlights.scm") ";; a comment\n;; inherits: base,(optional)\n(top)\n")
  (treesit-test:write-file! (folder "b/top/highlights.scm") ";inherits:top\n(top extended)\n")
  (treesit-test:write-file! (folder "a/optional/highlights.scm") ";; inherits: (base)\n(optional)\n")
  (let ([resolved (lambda (language) (query-files (list (folder "a") (folder "b")) language "highlights"))]
        [core (list (folder "a/core/highlights.scm") (folder "b/core/highlights.scm"))])
    (check-equal? core (resolved "core"))
    (check-equal? (append core (list (folder "a/base/highlights.scm"))) (resolved "base"))
    (check-equal? (append core (list (folder "a/base/highlights.scm") (folder "a/optional/highlights.scm")))
                  (resolved "optional"))
    (check-equal? (append core (list (folder "a/base/highlights.scm") (folder "a/optional/highlights.scm")
                                     (folder "a/top/highlights.scm") (folder "b/top/highlights.scm")))
                  (resolved "top"))
    (check-equal? '() (resolved "none"))))

(test "extending files come in the reverse of the folders' order, so the first folder's comes last"
  (treesit-test:write-file! (folder "x/ext/highlights.scm") "; extends\n(a)\n")
  (treesit-test:write-file! (folder "y/ext/highlights.scm") "; extends\n(b)\n")
  (treesit-test:write-file! (folder "z/ext/highlights.scm") "(c)\n")
  (check-equal? (list (folder "z/ext/highlights.scm") (folder "y/ext/highlights.scm") (folder "x/ext/highlights.scm"))
                (query-files (list (folder "x") (folder "y") (folder "z")) "ext" "highlights")))

(test "with every file compiled there is nothing to tell"
  (check-equal? '()
    (treesit-test/session:problems
      (treesit-test/session:highlighted grammar "x = 1\n" (treesit-test/session:shipped) excluded))))

(test "a file that does not compile is left out and told; the others, shipped files included, still colour"
  (treesit-test:write-file! user-file
    "; extends\n((identifier) @keyword\n  (#eq? @keyword \"breakpoint\"))\n\n  (no_such_node) @error\n")
  (let ([s (treesit-test/session:open grammar "breakpoint()\n'a'\n" (files) excluded)])
    (check-equal? '((0 17)) (treesit-test/session:settle! s))
    (check-equal? (list (list 'query-error user-file 5 3 "invalid node type")) (treesit-test/session:problems s))
    (check-equal? '(("breakpoint" function.builtin) ("'a'" string)) (treesit-test/session:runs s)))
  (treesit-test:write-file! user-file "; extends\n(identifier) @keyword (#eq? @keyword)\n")
  (let ([s (session "breakpoint()\n'a'\n")])
    (check-equal? (list (list 'query-error user-file 2 23 "wrong arguments to #eq?")) (treesit-test/session:problems s))
    (check-equal? '(("breakpoint" function.builtin) ("'a'" string)) (treesit-test/session:runs s))))
