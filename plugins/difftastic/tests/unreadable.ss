(import (tuna) (test) (test-user) (test-runner) (options) (diff-sections) (git) (git-mode) (git-status) (difftastic) (difftastic-test)
        (git-status-test) (git-test repositories))

(git-test/repositories:write-file! "odd difft" "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 'Difftastic 0.68.0'; else echo 'not json'; fi\n")
(git-test/repositories:run! "" "chmod" "+x" (git-test/repositories:path "odd difft"))
(options:set! difftastic:program (git-test/repositories:path "odd difft"))

(define warned '())

(define (keep next c) (when (warning? c) (set! warned (cons (condition-message c) warned))))

(test "output that is not difftastic's JSON leaves git's diff and warns once; a program path with a space runs as one word"
  (advice-add! report keep)
  (let ([repo (difftastic-test:rewrapped! "repo")])
    (test-runner:wait-until (lambda () (pair? warned)))
    (git-test/repositories:write-file! "repo/a.py" "def f():\n    foo(x, y)\n    return 4\n")
    (git-mode:refresh-repository repo)
    (git-status-test:settle!)
    (advice-remove! report keep)
    (check-equal? 1 (length warned))
    (check (string=? "difft could not be used: " (substring (car warned) 0 25)))
    (check-equal? '() (difftastic-test:refined-faces))))
