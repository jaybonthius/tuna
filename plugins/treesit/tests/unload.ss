(import (tuna) (test) (test-runner) (tables) (modes) (languages) (treesit) (python) (treesit-test) (treesit-test grammar))

(define python python:python)
(treesit-test/grammar:build-python! (languages:grammar-commit python) (treesit:grammar-file python))

(define coloured '(("def" keyword.function) ("f" function) ("x" variable.parameter) ("return" keyword.return)))

(define p (treesit-test:buffer "p.py" "def f(x):\n    return x\n" python:mode))

(test "turning treesit off takes every tree-sitter colour away and stops the jobs; Python buffers keep their mode and keys"
  (treesit-test:runs-become p coloured)
  (check-equal? '(start) (treesit-test:job-events))
  (unload-owner! (module-owner '(treesit)))
  (check-equal? '() (treesit-test:spans p))
  (check-equal? '(stop) (treesit-test:job-events))
  (check-equal? '(#f #t #t)
                (map (lambda (name) (and (member name (loaded-modules)) #t)) '((treesit) (python) (syntax-highlighting))))
  (check (eq? python:mode (modes:major-mode p)))
  (check (eq? python:keymap (tables:ref modes:keymaps python:mode #f))))

(test "loading treesit again colours them again"
  (load-module! '(treesit))
  (treesit-test:runs-become p coloured)
  (test-runner:wait-until (lambda () (equal? '(start) (treesit-test:job-events)))))
