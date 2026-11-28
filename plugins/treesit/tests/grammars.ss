(import (tuna) (test) (test-runner) (test-user) (tables) (options) (ask) (buffers) (syntax-highlighting) (languages) (treesit) (python)
        (buffers-test) (syntax-highlighting-test) (treesit-test) (treesit-test grammar) (treesit-test grammars missing)
        (treesit-test grammars elsewhere) (treesit-test grammars nowhere) (treesit-test grammars damaged))

(define python python:python)
(treesit-test/grammar:build-python! (languages:grammar-commit python) (treesit:grammar-file python))

(define told '())

(options:set! ask:message-writer (lambda (text) (set! told (cons text told))))

(define (take-told!)
  (let ([found (reverse told)])
    (set! told '())
    found))

(define (python-buffer name text) (treesit-test:buffer name text python:mode))

(define coloured '(("def" keyword.function) ("f" function) ("x" variable.parameter) ("return" keyword.return)))

(test "a grammar built from source has its file in Tuna's data folder, named by its name and its commit; one built elsewhere is its file"
  (check-equal? (treesit-test:home-file ".local/share/tuna/grammars/libtree-sitter-python-293fdc02038e.so")
                (treesit:grammar-file python))
  (check-equal? (treesit-test:home-file "elsewhere/python.so") (treesit:grammar-file treesit-test/grammars/elsewhere:python))
  (check-raises (buffers-test:raised-with? 'treesit:grammar-file "not a grammar" '("python")) (treesit:grammar-file "python")))

(define b (python-buffer "b.py" "def f(x):\n    return x\n"))

(test "a Python buffer is coloured with the grammar's captures"
  (treesit-test:runs-become b coloured))

(define c #f)

(test "a grammar from source whose file is missing draws its buffers plain and tells nothing"
  (tables:set! languages:grammar "python" treesit-test/grammars/missing:python)
  (syntax-highlighting:update!)
  (treesit-test:runs-become b '())
  (set! c (python-buffer "c.py" "def f(x):\n    return x\n"))
  (test-user:settle)
  (check-equal? '() (treesit-test:runs c))
  (check-equal? '() (take-told!)))

(test "a grammar built elsewhere is loaded as it is"
  (treesit-test:copy-file! (treesit:grammar-file python) (treesit-test:home-file "elsewhere/python.so"))
  (tables:set! languages:grammar "python" treesit-test/grammars/elsewhere:python)
  (syntax-highlighting:update!)
  (treesit-test:runs-become b coloured)
  (treesit-test:runs-become c coloured)
  (check-equal? '() (take-told!)))

(test "a grammar built elsewhere whose file is missing is told once a session, and its buffers are plain"
  (tables:set! languages:grammar "python" treesit-test/grammars/nowhere:python)
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
  (tables:set! languages:grammar "python" treesit-test/grammars/damaged:python)
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
  (tables:set! languages:grammar "python" "python")
  (let ([f #f])
    (check-equal? '((languages:grammar-of "the entry is not a grammar"))
                  (syntax-highlighting-test:reports-until 1 (lambda () (set! f (python-buffer "f.py" "x = 1\n")))))
    (check-equal? '() (treesit-test:runs f))))
