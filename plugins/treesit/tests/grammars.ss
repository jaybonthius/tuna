(import (tuna) (test) (test-runner) (test-user) (tables) (options) (ask) (buffers) (syntax-highlighting) (treesit) (python)
        (buffers-test) (syntax-highlighting-test) (treesit-test) (treesit-test grammar))

(define python (tables:ref treesit:grammars "python" #f))
(treesit-test/grammar:build-python! (treesit:grammar-commit python) (treesit:grammar-file python))

(define told '())

(options:set! ask:message-writer (lambda (text) (set! told (cons text told))))

(define (take-told!)
  (let ([found (reverse told)])
    (set! told '())
    found))

(define (python-buffer name text) (treesit-test:buffer name text python:mode))

(define coloured '(("def" keyword.function) ("f" function) ("x" variable.parameter) ("return" keyword.return)))

(define (prebuilt-at name) (treesit:make-prebuilt-grammar "python" (treesit-test:home-file name)))

(test "Python's grammar is tree-sitter-python at a pinned commit, built into Tuna's data folder, and Python's highlighter is the plugin's"
  (check-equal? '("python" "https://github.com/tree-sitter/tree-sitter-python" "293fdc02038ee2bf0e2e206711b69c90ac0d413f")
                (map (lambda (get) (get python)) (list treesit:grammar-name treesit:grammar-source treesit:grammar-commit)))
  (check-equal? (treesit-test:home-file ".local/share/tuna/grammars/libtree-sitter-python-293fdc02038e.so")
                (treesit:grammar-file python))
  (check (treesit:grammar? python))
  (check-equal? #f (treesit:grammar? "python"))
  (check (eq? treesit:highlighter (tables:ref syntax-highlighting:highlighters "python" #f))))

(test "a grammar's name is letters, digits and _, its source a string and its commit a full one"
  (let ([commit (treesit:grammar-commit python)])
    (check-raises (buffers-test:raised-with? 'treesit:make-grammar "not a grammar's name: letters, digits and _" '("py-thon"))
                  (treesit:make-grammar "py-thon" "https://example.org/x" commit))
    (check-raises (buffers-test:raised-with? 'treesit:make-grammar "not a URL or folder" '(url))
                  (treesit:make-grammar "python" 'url commit))
    (check-raises (buffers-test:raised-with? 'treesit:make-grammar "not a full commit: 40 hexadecimal digits" '("293fdc0"))
                  (treesit:make-grammar "python" "https://example.org/x" "293fdc0"))))

(test "a prebuilt grammar is named by its file, with no source or commit"
  (check-raises (buffers-test:raised-with? 'treesit:make-prebuilt-grammar "not a grammar's name: letters, digits and _" '(""))
                (treesit:make-prebuilt-grammar "" "/x.so"))
  (check-raises (buffers-test:raised-with? 'treesit:make-prebuilt-grammar "not a file name" '(#f))
                (treesit:make-prebuilt-grammar "djot" #f))
  (let ([prebuilt (treesit:make-prebuilt-grammar "python" "/opt/grammars/python.so")])
    (check-equal? '(#t "python" #f #f "/opt/grammars/python.so")
                  (list (treesit:grammar? prebuilt) (treesit:grammar-name prebuilt) (treesit:grammar-source prebuilt)
                        (treesit:grammar-commit prebuilt) (treesit:grammar-file prebuilt)))))

(define b (python-buffer "b.py" "def f(x):\n    return x\n"))

(test "a Python buffer is coloured with the grammar's captures"
  (treesit-test:runs-become b coloured))

(define c #f)

(test "a grammar from source whose file is missing draws its buffers plain and tells nothing"
  (tables:set! treesit:grammars "python"
    (treesit:make-grammar "python" "https://github.com/tree-sitter/tree-sitter-python" "0000000000000000000000000000000000000000"))
  (syntax-highlighting:update!)
  (treesit-test:runs-become b '())
  (set! c (python-buffer "c.py" "def f(x):\n    return x\n"))
  (test-user:settle)
  (check-equal? '() (treesit-test:runs c))
  (check-equal? '() (take-told!)))

(test "a grammar built elsewhere is loaded as it is"
  (treesit-test:copy-file! (treesit:grammar-file python) (treesit-test:home-file "elsewhere/python.so"))
  (tables:set! treesit:grammars "python" (prebuilt-at "elsewhere/python.so"))
  (syntax-highlighting:update!)
  (treesit-test:runs-become b coloured)
  (treesit-test:runs-become c coloured)
  (check-equal? '() (take-told!)))

(test "a prebuilt grammar's missing file is told once a session, and its buffers are plain"
  (tables:set! treesit:grammars "python" (prebuilt-at "nowhere/python.so"))
  (syntax-highlighting:update!)
  (treesit-test:runs-become b '())
  (treesit-test:runs-become c '())
  (test-runner:wait-until (lambda () (pair? told)))
  (check-equal? (list (string-append "No tree-sitter grammar for python at " (treesit-test:home-file "nowhere/python.so")))
                (take-told!))
  (let ([d (python-buffer "d.py" "x = 1\n")])
    (test-user:settle)
    (check-equal? '() (treesit-test:runs d))
    (check-equal? '() (take-told!))
    (buffers:kill! d)))

(test "a grammar file that does not load is told once a session, and its buffers are plain"
  (treesit-test:write-file! (treesit-test:home-file "damaged/python.so") "not a shared object\n")
  (tables:set! treesit:grammars "python" (prebuilt-at "damaged/python.so"))
  (syntax-highlighting:update!)
  (test-runner:wait-until (lambda () (pair? told)))
  (let ([damaged (treesit-test:home-file "damaged/python.so")])
    (check-equal? (list (format "Loading the tree-sitter grammar for python failed: cannot load tree_sitter_python from ~a: ~a: file too short"
                                damaged damaged))
                  (take-told!)))
  (check-equal? '() (treesit-test:runs b))
  (let ([e (python-buffer "e.py" "x = 1\n")])
    (test-user:settle)
    (check-equal? '() (treesit-test:runs e))
    (check-equal? '() (take-told!))
    (buffers:kill! e)))

(test "a table entry that is not a grammar is reported, and the buffer is plain"
  ;; A running job's later data reads its input again, which would raise
  ;; too.
  (for-each buffers:kill! (list b c))
  (tables:set! treesit:grammars "python" "python")
  (let ([f #f])
    (check-equal? '((treesit:grammars "not a grammar"))
                  (syntax-highlighting-test:reports-until 1 (lambda () (set! f (python-buffer "f.py" "x = 1\n")))))
    (check-equal? '() (treesit-test:runs f))))
