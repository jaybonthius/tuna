(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (tables) (timers) (buffers) (document) (views) (layout)
        (files) (xref) (processes) (diagnostics) (python) (lsp) (lsp-test servers) (lsp-test installed))

(lsp-test/installed:require-programs! '("basedpyright-langserver" "ruff" "python3"))

(options:set! lsp:send-changes-delay 0.05)

(tables:set! lsp:language-servers "python" (list lsp:basedpyright lsp:ruff))

(hooks:add! python:mode-hook lsp:ensure)

(define home lsp-test/servers:home)

(define (in-home path) (string-append home path))

(lsp-test/servers:write-file! (in-home "/loose/a.py") "import os\nfrom helpers import double\n\nprint(double(2))\n")
(lsp-test/servers:write-file! (in-home "/loose/helpers.py") "def double(x: int) -> int:\n    return x * 2\n")
(lsp-test/servers:write-file! (in-home "/loose/deep/ruff.toml") "this is not TOML [[\n")
(lsp-test/servers:write-file! (in-home "/elsewhere/b.py") "import sys\n")
(lsp-test/servers:write-file! (in-home "/tool/pyproject.toml") "[project]\nname = \"tool\"\nversion = \"0\"\n")
(lsp-test/servers:write-file! (in-home "/tool/pkg/setup.py") "")
(lsp-test/servers:write-file! (in-home "/tool/pkg/c.py") "import os\n")
(lsp-test/servers:write-file! (in-home "/super/.git/HEAD") "")
(lsp-test/servers:write-file! (in-home "/super/.git/modules/sub/HEAD") "")
(lsp-test/servers:write-file! (in-home "/super/sub/.git") (string-append "gitdir: " (in-home "/super/.git/modules/sub") "\n"))
(lsp-test/servers:write-file! (in-home "/super/sub/s.py") "import os\n")

(define (messages b)
  (map (lambda (d) (list (diagnostics:diagnostic-origin d) (diagnostics:diagnostic-code d) (diagnostics:diagnostic-message d)))
       (diagnostics:in b)))

(define (contains? s part)
  (let loop ([i 0])
    (and (<= (+ i (string-length part)) (string-length s))
         (or (string=? part (substring s i (+ i (string-length part)))) (loop (+ i 1))))))

(define (from-basedpyright? m) (equal? (car m) "basedpyright"))

(define (basedpyright-unused? name) (lambda (m) (and (from-basedpyright? m) (contains? (caddr m) (string-append "\"" name "\"")))))

(define (ruff-unused? m) (and (equal? (car m) "Ruff") (equal? (cadr m) "F401")))

(define (served? b name)
  (test-runner:wait-until (lambda () (and (exists (basedpyright-unused? name) (messages b)) (exists ruff-unused? (messages b))))))

(define (roots b) (map lsp:connection-root (lsp:buffer-connections b)))

(define a (lsp-test/servers:visit! (in-home "/loose/a.py")))

(test "basedpyright and ruff serve a file in no project with no root, and report its unused import"
  (served? a "os")
  (check-equal? '(#f #f) (roots a)))

(test "the module beside a file in no project resolves: nothing is unresolved, and M-. goes to its definition"
  (check-equal? '() (filter (lambda (m) (contains? (caddr m) "could not be resolved")) (messages a)))
  (views:set-point! (lsp-test/servers:view) (+ 1 (string-length "import os\nfrom helpers import ")))
  (lsp-test/servers:press-until-ended! "M-." xref:find-definitions)
  (check-equal? "helpers.py" (buffers:name (views:buffer (lsp-test/servers:view))))
  (test-user:press! "M-,"))

(test "a file in no project in another folder joins the same two connections and is served"
  (let ([b (lsp-test/servers:visit! (in-home "/elsewhere/b.py"))])
    (served? b "sys")
    (check-equal? '(2 #f #f) (cons (length (lsp:connections)) (roots b)))))

(test "ruff with no root does not walk the folder it runs in: it never reads the broken ruff.toml below, which a walk reports"
  (check-equal? '() (filter (lambda (text) (contains? text "Error while resolving settings")) (lsp-test/servers:said!))))

(define (standard-library-file)
  (let-values ([(status output errors) (processes:run "python3" '("-c" "import colorsys; print(colorsys.__file__, end='')"))])
    (utf8->string output)))

(test "basedpyright with no root checks a standard library file it is given"
  (let ([s (lsp-test/servers:visit! (standard-library-file))])
    (test-runner:wait-until (lambda () (exists from-basedpyright? (messages s))))
    (check-equal? '(#f #f) (roots s))))

(test "a folder with pyproject.toml and no repository is the root of both servers, though a setup.py lies nearer"
  (let ([c (lsp-test/servers:visit! (in-home "/tool/pkg/c.py"))])
    (served? c "os")
    (check-equal? (list (in-home "/tool/") (in-home "/tool/")) (roots c))))

(test "a file in a git submodule roots at the superproject, as projects:find gives it"
  (let ([s (lsp-test/servers:visit! (in-home "/super/sub/s.py"))])
    (served? s "os")
    (check-equal? (list (in-home "/super/") (in-home "/super/")) (roots s))))

(test "lsp:shutdown-all shuts down every connection"
  (lsp:shutdown-all)
  (check-equal? '() (lsp:connections)))
