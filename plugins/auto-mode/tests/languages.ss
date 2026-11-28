(import (tuna) (test) (auto-mode) (languages) (modes) (python) (files) (buffers) (hooks) (tables) (auto-mode-test declared))

(define make auto-mode-test/declared:make)
(define docker auto-mode-test/declared:docker)
(define dotenv auto-mode-test/declared:dotenv)
(define ssh auto-mode-test/declared:ssh)
(define shell auto-mode-test/declared:shell)
(define devfile auto-mode-test/declared:devfile)

(define b (buffers:make "b" "x"))

(define (modes-of names) (map (lambda (name) (auto-mode:by-file-name b name)) names))

(test "a language's names choose its mode: a whole name, then from each dot on, as written, then in lowercase"
  (check-equal? (list make make make make make #f)
                (modes-of '("/src/Makefile" "/src/makefile" "/src/GNUmakefile" "/src/x.mk" "/src/X.MK" "/src/Makefile.am"))))

(test "a glob with no / matches the last part of the name, * any run and ? one character"
  (check-equal? (list docker docker docker docker #f #f)
                (modes-of '("/a/Dockerfile" "/a/Dockerfile.dev" "/a/Dockerfile.seaweedfs" "/a/Containerfile.x" "/a/MyDockerfile.x"
                            "/a/Dockerfile/x"))))

(test "a whole name and a glob: .env and .env.example match, .envrc does not"
  (check-equal? (list dotenv dotenv dotenv #f) (modes-of '("/p/.env" "/p/.env.example" "/p/.env.default" "/p/.envrc"))))

(test "a glob with / matches the end of the path, its * matching no /"
  (check-equal? (list ssh ssh #f #f) (modes-of '("/home/u/.ssh/config" "/etc/ssh/ssh_config.d/local" "/home/u/config" "/home/u/.ssh/x/config"))))

(test "a whole name or a part after a dot beats any glob; of two globs the one with more characters that are not * or ? wins"
  (check-equal? (list docker devfile devfile shell)
                (modes-of '("/a/Dockerfile.dev" "/a/x.dev" "/a/x.devfile" "/etc/profile.d/x.sh"))))

(test "a name in the user's table beats a language's"
  (tables:set! auto-mode:file-names "Makefile" python:mode)
  (check-equal? (list python:mode make) (modes-of '("/src/Makefile" "/src/GNUmakefile")))
  (tables:remove! auto-mode:file-names "Makefile"))

(test "the user's table takes globs too, which beat a language's names"
  (tables:set! auto-mode:file-names "Dockerfile.*" python:mode)
  (tables:set! auto-mode:file-names "*.mk" python:mode)
  (check-equal? (list python:mode docker python:mode) (modes-of '("/a/Dockerfile.dev" "/a/Dockerfile" "/a/x.mk")))
  (tables:remove! auto-mode:file-names "Dockerfile.*")
  (tables:remove! auto-mode:file-names "*.mk"))

(test "a program on a #! line chooses its language's mode, as written or without a version; the user's table comes first"
  (define (by-line line) (auto-mode:by-interpreter (buffers:make (buffers:free-name "script") line) "script"))
  (check-equal? (list shell shell #f) (map by-line '("#!/bin/sh\n" "#!/usr/bin/env bash5.2\n" "#!/bin/zsh\n")))
  (tables:set! auto-mode:interpreters "bash" python:mode)
  (check-equal? python:mode (by-line "#!/bin/bash\n"))
  (tables:remove! auto-mode:interpreters "bash"))

(test "a #! line beats the file's name, since by-interpreter comes first"
  (let ([script (buffers:make "x.py" "#!/bin/sh\necho\n")])
    (check-equal? shell (auto-mode:choose script "/p/x.py"))))

(test "a language with no mode chooses nothing"
  (languages:define-language "modeless" (file-names "modeless"))
  (check-equal? #f (auto-mode:by-file-name b "/p/a.modeless")))

(test "an entry that is not a list of strings is reported, naming the table and the language"
  (tables:set! languages:file-names "devfile" "devfile")
  (check-raises (lambda (c) (and (who-condition? c) (eq? 'languages:file-names-of (condition-who c))
                                 (equal? '("devfile" "devfile") (condition-irritants c))))
                (auto-mode:by-file-name b "/p/a.devfile"))
  (tables:remove! languages:file-names "devfile"))

(define (home-file name) (string-append (getenv "HOME") "/" name))

(test "turning the declaring plugin off stops its names matching; its buffers keep their mode"
  (call-with-output-file (home-file "Makefile") (lambda (p) (put-string p "all:\n")) 'replace)
  (let ([m (files:visit (home-file "Makefile"))])
    (check-equal? make (modes:major-mode m))
    (unload-owner! (module-owner '(auto-mode-test declared)))
    (check-equal? #f (auto-mode:by-file-name b "/src/Makefile"))
    (check-equal? make (modes:major-mode m))))
