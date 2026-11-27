(import (tuna) (test) (test-runner) (test-user) (tables) (options) (hooks) (ask) (modes) (syntax-highlighting)
        (treesit) (python) (syntax-highlighting-test) (treesit-test) (treesit-test grammar))

(define python (tables:ref treesit:grammars "python" #f))
(treesit-test/grammar:build-python! (treesit:grammar-commit python) (treesit:grammar-file python))

(define told '())

(options:set! ask:message-writer (lambda (text) (set! told (cons text told))))

(define text "x = len(y)\n")

(define pyish-queries (treesit-test:home-file ".config/tuna/lib/pyish/queries/python/highlights.scm"))

(treesit-test:write-file! (treesit-test:home-file ".config/tuna/lib/pyish.sls")
  "#!tuna\n(import (modes) (hooks) (tables))\n(tables:define-table keymap \"Keys.\")\n(hooks:define-hook mode-hook \"Setup.\")\n(modes:define-major-mode mode (keymap keymap) (hook mode-hook) (language \"python\"))\n")
(import (pyish))

(test "Python's own query file sits in the python plugin's folder, and treesit reads it because python:mode declares the language: an assignment's target is a definition"
  (treesit-test:runs-become (treesit-test:buffer "a.py" text python:mode)
    '(("x" variable.definition) ("len" function.builtin))))

(test "a plugin whose mode declares a language adds the queries folder beside its module, for the buffers of every mode of that language"
  (treesit-test:write-file! pyish-queries "; extends\n((identifier) @constant (#eq? @constant \"y\"))\n")
  (treesit-test:runs-become (treesit-test:buffer "b.py" text python:mode)
    '(("x" variable.definition) ("len" function.builtin) ("y" constant)))
  (treesit-test:runs-become (treesit-test:buffer "c" text pyish:mode)
    '(("x" variable.definition) ("len" function.builtin) ("y" constant))))

(test "of two such plugins, the first to declare the language wins where their files capture the same text"
  (treesit-test:write-file! pyish-queries "; extends\n((identifier) @constant (#any-of? @constant \"x\" \"y\"))\n")
  (treesit-test:runs-become (treesit-test:buffer "d" text pyish:mode)
    '(("x" variable.definition) ("len" function.builtin) ("y" constant))))

(tables:define-table here-keymap "Keys.")
(hooks:define-hook here-hook "Setup.")
(modes:define-major-mode here (keymap here-keymap) (hook here-hook) (language "python"))

(test "a mode declared outside a plugin has no folder, and its buffers take the files of the plugins that declare its language"
  (treesit-test:runs-become (treesit-test:buffer "e" text here)
    '(("x" variable.definition) ("len" function.builtin) ("y" constant))))

(define f #f)

(test "with python off its file is no longer read; turning it on again gives its file to the open buffers of the language"
  (unload-owner! (module-owner '(python)))
  (set! f (treesit-test:buffer "f" text pyish:mode))
  (treesit-test:runs-become f '(("x" constant) ("len" function.builtin) ("y" constant)))
  (load-module! '(python))
  (treesit-test:runs-become f '(("x" variable.definition) ("len" function.builtin) ("y" constant))))

(test "reloading a plugin after its query file changed gives its open buffers the new file"
  (treesit-test:write-file! pyish-queries "; extends\n((identifier) @keyword (#eq? @keyword \"y\"))\n")
  (reload-modules! '((pyish)))
  (treesit-test:runs-become f '(("x" variable.definition) ("len" function.builtin) ("y" keyword))))

(test "turning a plugin off takes its colours from its own mode's buffers at once; another mode's buffers keep its files until their input is next read"
  (let ([g (treesit-test:buffer "g.py" text python:mode)])
    (treesit-test:runs-become g '(("x" variable.definition) ("len" function.builtin) ("y" keyword)))
    (unload-owner! (module-owner '(pyish)))
    (treesit-test:runs-become f '())
    (test-user:settle)
    (check-equal? '(("x" variable.definition) ("len" function.builtin) ("y" keyword)) (treesit-test:runs g))
    (syntax-highlighting:update! g)
    (treesit-test:runs-become g '(("x" variable.definition) ("len" function.builtin)))))

(test "a buffer whose mode has lost its language tells no query problem of its job, and is drawn plain"
  (treesit-test:write-file! (treesit-test:home-file ".config/tuna/queries/python/highlights.scm") "; extends\n(no_such_node) @error\n")
  (set! told '())
  (let ([h (treesit-test:buffer "h" text here)])
    (test-runner:wait-until (lambda () (pair? told)))
    (check-equal? '() (syntax-highlighting-test:reports-until 0
                        (lambda ()
                          (tables:remove! modes:languages here)
                          (syntax-highlighting:update!))))
    (treesit-test:runs-become h '())))
