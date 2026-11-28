(import (tuna) (test) (tables) (languages) (treesit) (python) (treesit-test grammar) (treesit-test session))

(define python python:python)
(define grammar (treesit:grammar-file python))
(treesit-test/grammar:build-python! (languages:grammar-commit python) grammar)

(define (queried text query)
  (treesit-test/session:runs (treesit-test/session:highlighted grammar text (list (treesit-test/session:query! query)) '())))

(define (matched predicate)
  (map car (filter (lambda (run) (equal? (cadr run) '(n string)))
                   (queried "[a, a]\n[a, b]\n[b, c]\n"
                            (string-append "((list (identifier) @n (identifier) @n) @string " predicate ")")))))

(define (problems query)
  (let* ([file (treesit-test/session:query! query)]
         [s (treesit-test/session:open grammar "x = 1\n" (list file) '())])
    (treesit-test/session:settle! s)
    (list (map (lambda (p) (if (equal? (cadr p) file) (cons* (car p) 'that-file (cddr p)) p))
               (treesit-test/session:problems s))
          (treesit-test/session:runs s))))

(test "each text predicate tests every node of its capture, its any- form some node, and not- negates the whole test"
  (for-each
    (lambda (name pattern)
      (check-equal? '(("a" "a") ("a" "a" "a" "b") ("a" "b" "b" "c") ("b" "c"))
        (map (lambda (form) (matched (format "(#~a? @n \"~a\")" form pattern)))
             (list name (string-append "any-" name) (string-append "not-" name) (string-append "not-any-" name)))))
    '("eq" "match" "vim-match" "lua-match" "contains")
    '("a" "^a$" "^a$" "^a$" "a")))

(test "any-of? passes when some node is one of the strings"
  (check-equal? '(("a" "a" "a" "b") ("b" "c"))
    (map matched '("(#any-of? @n \"a\" \"x\")" "(#not-any-of? @n \"a\" \"x\")"))))

(test "kind-eq? tests every node's type, any-kind-eq? some node's"
  (check-equal? '(("a" "a" "a" "b" "b" "c") () ("a" "a" "a" "b" "b" "c"))
    (map matched '("(#kind-eq? @n \"identifier\")" "(#any-kind-eq? @n \"string\")" "(#not-kind-eq? @n \"string\")"))))

(test "a test of a capture with no node passes, so its not- form fails"
  (let ([calls (lambda (predicate)
                 (queried "f()\ng(x)\nh(y)\n"
                   (string-append "((call function: (identifier) @function arguments: (argument_list (identifier)? @a)) "
                                  predicate ")")))])
    (check-equal? '(("f" function) ("g" function) ("x" a)) (calls "(#eq? @a \"x\")"))
    (check-equal? '(("h" function) ("y" a)) (calls "(#not-eq? @a \"x\")"))
    (check-equal? '(("f" function) ("g" function) ("x" a)) (calls "(#any-of? @a \"x\")"))
    (check-equal? '(("h" function) ("y" a)) (calls "(#not-any-of? @a \"x\")"))
    (check-equal? '(("f" function) ("g" function) ("x" a) ("h" function) ("y" a)) (calls "(#has-ancestor? @a call)"))
    (check-equal? '() (calls "(#not-has-parent? @a argument_list)"))))

(test "eq? compares with a string or with another capture's text"
  (check-equal? '(("self" keyword)) (queried "self.a = b\n" "((identifier) @keyword (#eq? @keyword \"self\"))"))
  (check-equal? '(("a" x) ("a" y))
    (queried "a = a\nb = c\n" "((assignment left: (identifier) @x right: (identifier) @y) (#eq? @x @y))")))

(test "contains? needs every string, any-contains? one"
  (check-equal? '(("abc" x) ("ab" x)) (queried "abc\nab\nb\n" "((identifier) @x (#contains? @x \"a\" \"b\"))"))
  (check-equal? '(("abc" x) ("ab" x) ("b" x)) (queried "abc\nab\nb\nc\n" "((identifier) @x (#any-contains? @x \"a\" \"b\"))")))

(test "the tree predicates name node types: of any ancestor, of the parent, of the node itself"
  (check-equal? '(("int" type)) (queried "x: int = 1\ny = int\n" "((identifier) @type (#has-ancestor? @type type))"))
  (check-equal? '() (queried "x: int = 1\ny = int\n" "((identifier) @type (#not-has-ancestor? @type type assignment))"))
  (check-equal? '(("a" x) ("b" x) ("c" x)) (queried "f(a)\nb.c\n" "((identifier) @x (#has-parent? @x argument_list attribute))"))
  (check-equal? '(("f" x) ("b" x) ("c" x)) (queried "f(a)\nb.c\n" "((identifier) @x (#not-has-parent? @x argument_list))"))
  (check-equal? '(("f(" x) ("a" (x x)) (")" x)) (queried "f(a)\n" "((_) @x (#kind-eq? @x \"argument_list\" \"identifier\"))")))

(test "an ancestor predicate may name more types than a fixnum has bits"
  (check-equal? '(("int" type))
    (queried "x: int = 1\ny = int\n"
      (string-append "((identifier) @type (#has-ancestor? @type"
                     (apply string-append (map (lambda (k) (format " kind~a" k)) (iota 80)))
                     " type))"))))

(test "match? is Vim's very magic regular expression"
  (check-equal? '(("LIST" x) ("list" x)) (queried "LIST list Lisp\n" "((identifier) @x (#match? @x \"\\\\c^list$\"))"))
  (check-equal? '(("a12" x) ("a123" x)) (queried "ab1 a12 a123\n" "((identifier) @x (#match? @x \"^a\\\\d{2,3}$\"))"))
  (check-equal? '(("ab" x) ("ac" x)) (queried "ab ac ad\n" "((identifier) @x (#match? @x \"^a%(b|c)$\"))"))
  (check-equal? '(("a" x) ("ab" x)) (queried "a ab abb\n" "((identifier) @x (#match? @x \"^ab=$\"))"))
  (check-equal? '(("'axb'" x)) (queried "x = '''a\nb'''\ny = 'axb'\n" "((string) @x (#match? @x \"a.b\"))"))
  (check-equal? '(("bar" x)) (queried "foo_bar bar\n" "((identifier) @x (#match? @x \"<bar\"))")))

(test "lua-match? is a Lua pattern: classes, sets, - as a lazy *, % quoting, and characters such as | that are themselves"
  (check-equal? '(("Abc" x)) (queried "Abc abc ABC\n" "((identifier) @x (#lua-match? @x \"^%u%l+$\"))"))
  (check-equal? '(("r'" x)) (queried "x = r'a'\ny = 'a'\n" "((string_start) @x (#lua-match? @x \"^%a+['\\\"]$\"))"))
  (check-equal? '(("a1" x) ("a_" x)) (queried "a1 a_ a.b\n" "((identifier) @x (#lua-match? @x \"^a[%d_]$\"))"))
  (check-equal? '(("aab" x) ("b" x)) (queried "a aa aab b\n" "((identifier) @x (#lua-match? @x \"^a-b$\"))"))
  (check-equal? '(("a.b" x)) (queried "x = 'a.b'\ny = 'axb'\n" "((string_content) @x (#lua-match? @x \"^a%.b$\"))"))
  (check-equal? '(("a|b" x)) (queried "x = 'a|b'\ny = 'a'\n" "((string_content) @x (#lua-match? @x \"a|b\"))")))

(test "#offset! moves a capture's edges by rows and columns"
  (check-equal? '(("'a" string)) (queried "x = r'a'\n" "((string) @string (#offset! @string 0 1 0 -1))"))
  (check-equal? '(("y = 2" x)) (queried "x = 1\ny = 2\n" "((expression_statement) @x (#offset! @x 1 0 1 0))")))

(test "#trim! trims the blank lines at the end, or with four flags blank lines and spaces at either end"
  (check-equal? '(("\n\n  a  " x)) (queried "x = '''\n\n  a  \n\n'''\n" "((string_content) @x (#trim! @x))"))
  (check-equal? '(("a" x)) (queried "x = '''\n\n  a  \n\n'''\n" "((string_content) @x (#trim! @x 1 1 1 1))")))

(test "#gsub! rewrites text no colour uses"
  (check-equal? '(("'a'" x)) (queried "x = 'a'\n" "((string) @x (#gsub! @x \"a\" \"b\"))")))

(test "#set! gives a pattern, or one of its captures, a priority; a value that is a capture colours nothing"
  (check-equal? '(("x" y)) (queried "x = 1\n" "((identifier) @x (#set! priority 99)) ((identifier) @y)"))
  (check-equal? '(("x" x)) (queried "x = 1\n" "((identifier) @x (#set! \"priority\" \"101\")) ((identifier) @y)"))
  (check-equal? '(("x" x)) (queried "x = 1\n" "((identifier) @x (#set! @x priority 101)) ((identifier) @y)"))
  (check-equal? '(("'" x) ("a" (y x)) ("'" x)) (queried "x = 'a'\n" "((string (string_content) @y) @x (#set! @x url @y))")))

(test "any other predicate or directive is a query error, told with the file, the row from 1 and the column from 0, and the file is left out"
  (check-equal? '(((query-error that-file 1 18 "unknown predicate #is?")) ()) (problems "((identifier) @x (#is? @x local))"))
  (check-equal? '(((query-error that-file 2 3 "unknown predicate #foo?")) ()) (problems "((identifier) @x\n  (#foo? @x))"))
  (check-equal? '(((query-error that-file 1 18 "unknown directive #strip!")) ()) (problems "((identifier) @x (#strip! @x))"))
  (check-equal? '(((query-error that-file 1 18 "unknown predicate #any-not-eq?")) ())
                (problems "((identifier) @x (#any-not-eq? @x \"a\"))"))
  (check-equal? '(((query-error that-file 1 18 "wrong arguments to #eq?")) ()) (problems "((identifier) @x (#eq? @x))"))
  (check-equal? '(((query-error that-file 1 18 "#offset! takes a capture and up to four integers")) ())
                (problems "((identifier) @x (#offset! @x a))"))
  (check-equal? '(((query-error that-file 1 18 "#trim! takes a capture and none or four of 0 and 1")) ())
                (problems "((identifier) @x (#trim! @x 1 2))")))

(test "a pattern construct POSIX lacks is a query error, not a different match"
  (check-equal? '(((query-error that-file 1 18 "Vim's \\z has no POSIX translation")) ())
                (problems "((identifier) @x (#match? @x \"a\\\\zsb\"))"))
  (check-equal? '(((query-error that-file 1 18 "Vim's @ has no POSIX translation")) ())
                (problems "((identifier) @x (#match? @x \"a@<=b\"))"))
  (check-equal? '(((query-error that-file 1 18 "Vim's \\V mode has no POSIX translation")) ())
                (problems "((identifier) @x (#match? @x \"\\\\Va\"))"))
  (check-equal? '(((query-error that-file 1 18 "Lua's %b has no POSIX translation")) ())
                (problems "((identifier) @x (#lua-match? @x \"%b()\"))"))
  (check-equal? '(((query-error that-file 1 18 "Lua's %f has no POSIX translation")) ())
                (problems "((identifier) @x (#lua-match? @x \"%f[%w]\"))")))

(test "tree-sitter's own errors point into the file too"
  (check-equal? '(((query-error that-file 2 3 "invalid node type")) ())
                (problems "((identifier) @x (#eq? @x \"x\"))\n  (no_such_node) @y")))
