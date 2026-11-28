(import (tuna) (test) (test-user) (tables) (options) (ask) (buffers) (document) (commands) (modes) (files) (auto-mode) (undo) (kill-ring)
        (languages) (treesit) (python) (treesit-test) (treesit-test grammar) (treesit-test session))

(define python python:python)
(treesit-test/grammar:build-python! (languages:grammar-commit python) (treesit:grammar-file python))

(define (fresh-runs b)
  (treesit-test/session:runs
    (treesit-test/session:highlighted (treesit:grammar-file python) (treesit-test:text-of b) (treesit-test/session:shipped)
      (options:default treesit:excluded-captures))))

(define (as-fresh b) (treesit-test:runs-become b (fresh-runs b)))

(define coloured '(("def" keyword.function) ("f" function) ("x" variable.parameter) ("return" keyword.return)))

(define b (treesit-test:buffer "b.py" "def f(x):\n    return x\n" python:mode))

(test "an undone edit leaves the colours of a buffer opened on the text"
  (treesit-test:runs-become b coloured)
  (buffers:with-buffer b
    (undo:with-edit-group b (buffers:insert! b (treesit-test:line-start b 2) "class C:\n    \"\"\"Doc.\"\"\"\n")))
  (treesit-test:runs-become b
    '(("def" keyword.function) ("f" function) ("x" variable.parameter) ("class" keyword.type) ("C" type)
      ("\"\"\"Doc.\"\"\"" string.documentation) ("return" keyword.return)))
  (let ([told '()])
    (options:with ([ask:message-writer (lambda (text) (set! told (cons text told)))])
      (buffers:with-buffer b (commands:run undo:undo 1)))
    (check-equal? '("Undo") told))
  (check-equal? "def f(x):\n    return x\n" (treesit-test:text-of b))
  (treesit-test:runs-become b coloured)
  (check-equal? coloured (fresh-runs b)))

(define r-file (treesit-test:home-file "r.py"))

(test "a revert, and a formatter's edit of the whole buffer, are edits as any other"
  (treesit-test:write-file! r-file "x = 1\n")
  (let ([r (files:visit r-file)])
    (check (eq? python:mode (modes:major-mode r)))
    (treesit-test:runs-become r '(("x" variable.definition) ("1" number)))
    (treesit-test:write-file! r-file "import os\n\n\ndef g(y=2):\n    '''Doc.'''\n    return os.sep\n")
    (files:revert-from-file r)
    (treesit-test:runs-become r
      '(("import" keyword.import) ("def" keyword.function) ("g" function) ("y" variable.parameter) ("2" number)
        ("'''Doc.'''" string.documentation) ("return" keyword.return)))
    (as-fresh r)
    (buffers:replace! r 1 (- (document:length (buffers:document r)) 1)
                      "import os\n\n\ndef g(y = 2):\n    \"\"\"Doc.\"\"\"\n    return os.sep\n")
    (treesit-test:runs-become r
      '(("import" keyword.import) ("def" keyword.function) ("g" function) ("y" variable.parameter) ("2" number)
        ("\"\"\"Doc.\"\"\"" string.documentation) ("return" keyword.return)))
    (as-fresh r)))

(test "a kill holds text, not colours: yanked into a buffer with no highlighter it stays plain; into a Python buffer it is coloured once parsed"
  (kill-ring:push! (list (buffers:piece b (treesit-test:line-start b 1) (treesit-test:line-start b 3))))
  (check-equal? "def f(x):\n    return x\n" (kill-ring:text (kill-ring:current)))
  (let ([plain (buffers:make "plain" "\n")])
    (kill-ring:insert! plain (treesit-test:line-start plain 2) (car (kill-ring:current)))
    (test-user:settle)
    (check-equal? "\ndef f(x):\n    return x\n" (treesit-test:text-of plain))
    (check (for-all (lambda (layer) (null? (buffers:spans layer 0 (document:length (buffers:document plain)))))
                    (buffers:layers plain))))
  (let ([p (treesit-test:buffer "p.py" "x = 1\n" python:mode)])
    (treesit-test:runs-become p '(("x" variable.definition) ("1" number)))
    (kill-ring:insert! p (treesit-test:line-start p 2) (car (kill-ring:current)))
    (treesit-test:runs-become p (cons* '("x" variable.definition) '("1" number) coloured))
    (as-fresh p)))

(test "with a syntax error, the text around it keeps its colours and the error gets none"
  (treesit-test:runs-become (treesit-test:buffer "e.py" "x = 1\ndef f(:\n    pass\ny = \"s\"\n" python:mode)
    '(("x" variable.definition) ("1" number) ("def" keyword.function) ("f" function) ("pass" keyword) ("y" variable.definition)
      ("\"s\"" string))))
