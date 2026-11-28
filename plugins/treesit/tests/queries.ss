(import (tuna) (test) (test-runner) (test-user) (tables) (options) (hooks) (ask) (modes) (syntax-highlighting)
        (languages) (treesit) (python) (syntax-highlighting-test) (treesit-test) (treesit-test grammar))

(define python python:python)
(treesit-test/grammar:build-python! (languages:grammar-commit python) (treesit:grammar-file python))

(define told '())

(options:set! ask:message-writer (lambda (text) (set! told (cons text told))))

(define text "x = len(y)\n")

(define pyish-queries (treesit-test:home-file ".config/tuna/lib/pyish/queries/python/highlights.scm"))

(treesit-test:write-file! (treesit-test:home-file ".config/tuna/lib/pyish.sls")
  "#!tuna\n(import (languages) (modes) (python) (hooks) (tables))\n(tables:define-table keymap \"Keys.\")\n(hooks:define-hook mode-hook \"Setup.\")\n(modes:define-major-mode mode (keymap keymap) (hook mode-hook))\n(languages:define-language \"pyish\" (mode mode) (grammar python:python))\n")
(import (pyish))

(test "Python's own query file sits in the python plugin's folder, which treesit searches as it searches every loaded plugin's: an assignment's target is a definition"
  (treesit-test:runs-become (treesit-test:buffer "a.py" text python:mode)
    '(("x" variable.definition) ("len" function.builtin))))

(define all-three '(("x" variable.definition) ("len" function.builtin) ("y" constant)))

(test "the queries folder beside each loaded plugin's module, under the grammar's name, serves every language of that grammar, as Neovim's runtime path does: a language borrowing python's grammar gets python's file, and python gets the borrower's"
  (treesit-test:write-file! pyish-queries "; extends\n((identifier) @constant (#eq? @constant \"y\"))\n")
  (treesit-test:runs-become (treesit-test:buffer "b" text pyish:mode) all-three)
  (treesit-test:runs-become (treesit-test:buffer "c.py" text python:mode) all-three))

(test "a grammar entry made outside a plugin leaves the plugins' files in use"
  (languages:define-language "python" (grammar python))
  (syntax-highlighting:update!)
  (treesit-test:runs-become (treesit-test:buffer "d.py" text python:mode) all-three))

(tables:define-table mine-keymap "Keys.")
(hooks:define-hook mine-hook "Setup.")
(modes:define-major-mode mine (keymap mine-keymap) (hook mine-hook))

(test "a configuration that gives Python a mode of its own, derived from none, keeps the python plugin's query file"
  (let ([configuration (make-owner '(configuration))])
    (call-as-owner configuration (lambda () (languages:define-language "python" (mode mine)) (void)))
    (treesit-test:runs-become (treesit-test:buffer "m.py" text mine) all-three)
    (unload-owner! configuration)))

(tables:define-table here-keymap "Keys.")
(hooks:define-hook here-hook "Setup.")
(modes:define-major-mode here (keymap here-keymap) (hook here-hook))
(languages:define-language "here" (mode here) (grammar python))

(test "a language declared outside a plugin has no folder of its own, and its buffers take the loaded plugins' files for its grammar"
  (treesit-test:runs-become (treesit-test:buffer "e" text here) all-three))

(define f #f)

(test "with pyish off its file is no longer read; turning it on again gives its file to the open buffers of the language"
  (set! f (treesit-test:buffer "f" text pyish:mode))
  (treesit-test:runs-become f all-three)
  (unload-owner! (module-owner '(pyish)))
  (treesit-test:runs-become f '())
  (load-module! '(pyish))
  (treesit-test:runs-become f all-three))

(test "reloading a plugin after its query file changed gives its open buffers the new file"
  (treesit-test:write-file! pyish-queries "; extends\n((identifier) @keyword (#eq? @keyword \"y\"))\n")
  (reload-modules! '((pyish)))
  (treesit-test:runs-become f '(("x" variable.definition) ("len" function.builtin) ("y" keyword))))

(test "a buffer whose mode has lost its language tells no query problem of its job, and is drawn plain"
  (treesit-test:write-file! (treesit-test:home-file ".config/tuna/queries/python/highlights.scm") "; extends\n(no_such_node) @error\n")
  (set! told '())
  (let ([h (treesit-test:buffer "h" text here)])
    (test-runner:wait-until (lambda () (pair? told)))
    (check-equal? '() (syntax-highlighting-test:reports-until 0
                        (lambda ()
                          (tables:remove! languages:mode "here")
                          (syntax-highlighting:update!))))
    (treesit-test:runs-become h '())))
