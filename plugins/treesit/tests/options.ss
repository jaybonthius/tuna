(import (tuna) (test) (test-runner) (tables) (options) (hooks) (ask) (buffers) (modes) (auto-mode)
        (syntax-highlighting) (treesit) (python) (treesit-test) (treesit-test grammar))

(define python (tables:ref treesit:grammars "python" #f))
(treesit-test/grammar:build-python! (treesit:grammar-commit python) (treesit:grammar-file python))

(define told '())

(options:set! ask:message-writer (lambda (text) (set! told (cons text told))))

(tables:define-table pyish-keymap "Keys.")
(hooks:define-hook pyish-hook "Setup.")
(modes:define-major-mode pyish (keymap pyish-keymap) (hook pyish-hook) (language "python"))

(define text "print(len(x))\n")

(define builtins '(("print" function.builtin) ("len" function.builtin)))

(define with-brackets
  '(("print" function.builtin) ("(" punctuation.bracket) ("len" function.builtin) ("(" punctuation.bracket) ("))" punctuation.bracket)))

(define (with-print face)
  (cons (list "print" face) (cdr with-brackets)))

(define user-file (treesit-test:home-file ".config/tuna/queries/python/highlights.scm"))

(define p (treesit-test:buffer "p.py" text python:mode))
(define q (treesit-test:buffer "q" text pyish))
(define r #f)
(define s #f)

(test "by default calls, uses and brackets are plain, and builtins coloured"
  (treesit-test:runs-become p builtins)
  (treesit-test:runs-become q builtins))

(test "a local setting in Python's mode hook changes Python buffers only, not another mode's buffers of the language"
  (hooks:add! python:mode-hook (lambda () (options:set-local! treesit:excluded-captures '(variable))))
  (set! r (treesit-test:buffer "r.py" text python:mode))
  (set! s (treesit-test:buffer "s" text pyish))
  (treesit-test:runs-become r with-brackets)
  (treesit-test:runs-become s builtins)
  (check-equal? builtins (treesit-test:runs p)))

(test "a change of the option while buffers are open highlights them again"
  (options:set! treesit:excluded-captures (cons 'function.builtin (options:default treesit:excluded-captures)))
  (for-each (lambda (b) (treesit-test:runs-become b '())) (list p q s))
  (check-equal? with-brackets (treesit-test:runs r))
  (options:unset! treesit:excluded-captures)
  (treesit-test:runs-become p builtins)
  (treesit-test:runs-become q builtins))

(test "a setting in one buffer changes that buffer only"
  (buffers:with-buffer r (options:set-local! treesit:excluded-captures '()))
  (treesit-test:runs-become r
    '(("print" function.builtin) ("(" punctuation.bracket) ("len" function.builtin) ("(" punctuation.bracket) ("x" variable)
      ("))" punctuation.bracket)))
  (check-equal? builtins (treesit-test:runs p)))

(define u #f)

(test "a user's file in the default folder, starting ; extends, is used with no setting, after nvim-treesitter's and the python plugin's, so its patterns win"
  (treesit-test:write-file! user-file "; extends\n((identifier) @keyword.debug (#eq? @keyword.debug \"print\"))\n")
  (set! u (treesit-test:buffer "u.py" text python:mode))
  (treesit-test:runs-become u (with-print 'keyword.debug)))

(test "another folder in the option is searched instead, and open buffers read it at once"
  (treesit-test:write-file! (treesit-test:home-file "mine/python/highlights.scm")
    "; extends\n((identifier) @constant (#eq? @constant \"print\"))\n")
  (options:set! treesit:query-folders (list (treesit-test:home-file "mine")))
  (treesit-test:runs-become u (with-print 'constant))
  (options:set! treesit:query-folders '("~/.config/tuna/queries/"))
  (treesit-test:runs-become u (with-print 'keyword.debug)))

(test "a query file edited on disk is read again the next time the buffer's input is, with no new job"
  (treesit-test:job-events)
  (treesit-test:write-file! user-file "; extends\n((identifier) @string.special (#eq? @string.special \"print\"))\n")
  (syntax-highlighting:update! u)
  (treesit-test:runs-become u (with-print 'string.special))
  (check-equal? '() (treesit-test:job-events)))

(test "setting the mode again, or normal-mode choosing it, starts the job again"
  (modes:set-major-mode python:mode u)
  (test-runner:wait-until (lambda () (equal? '(stop start) (treesit-test:job-events))))
  (treesit-test:runs-become u (with-print 'string.special))
  (auto-mode:normal-mode u)
  (check (eq? python:mode (modes:major-mode u)))
  (test-runner:wait-until (lambda () (equal? '(stop start) (treesit-test:job-events))))
  (treesit-test:runs-become u (with-print 'string.special)))

(test "a user's file that does not compile is left out, and told once, with its row and column"
  (treesit-test:write-file! user-file "; extends\n(no_such_node) @error\n")
  (set! told '())
  (let ([v (treesit-test:buffer "v.py" text python:mode)] [w (treesit-test:buffer "w.py" text python:mode)])
    (treesit-test:runs-become v with-brackets)
    (treesit-test:runs-become w with-brackets)
    (test-runner:wait-until (lambda () (pair? told)))
    (check-equal? '("Python highlights query: invalid node type at row 2, column 1 (~/.config/tuna/queries/python/highlights.scm)")
                  told)))
