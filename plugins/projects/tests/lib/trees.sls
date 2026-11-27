#!tuna
(import (processes) (projects) (test-runner))

(define (path name) (string-append (getenv "HOME") "/" name))

;; A test's home has no git configuration, and git commits only with a
;; name and an address.
(define %identity
  '(("GIT_AUTHOR_NAME" . "Tuna") ("GIT_AUTHOR_EMAIL" . "tuna@example.org")
    ("GIT_COMMITTER_NAME" . "Tuna") ("GIT_COMMITTER_EMAIL" . "tuna@example.org")))

(define (run! folder program . arguments)
  (let-values ([(status output errors)
                (processes:run program arguments #f (processes:options [directory (path folder)] [environment %identity]))])
    (unless (eqv? status 0)
      (error 'trees:run! (utf8->string output) (cons program arguments)))))

(define (write-file! name text)
  (run! "" "mkdir" "-p" (path-parent (path name)))
  (call-with-output-file (path name) (lambda (p) (put-string p text)) 'replace))

(define (repository! folder files)
  (for-each (lambda (file) (write-file! (string-append folder "/" (car file)) (cdr file))) files)
  (run! folder "git" "init" "-q" "-b" "main")
  (run! folder "git" "add" "-A")
  (run! folder "git" "commit" "-qm" "one"))

;; Git refuses a submodule from a local path unless allowed.
(define (add-submodule! folder from to)
  (run! folder "git" "-c" "protocol.file.allow=always" "submodule" "add" "-q" (path from) to))

(define (make!)
  (repository! "src/inner" '(("inner.ss" . "i\n")))
  (repository! "src/lib" '(("lib.ss" . "l\n")))
  (add-submodule! "src/lib" "src/inner" "vendor/inner")
  (run! "src/lib" "git" "commit" "-qm" "inner")
  (repository! "src/app"
    '(("README" . "r\n") ("lib/a.ss" . "a\n") ("lib/deep/b.ss" . "b\n") (".gitignore" . "*.log\nbuild/\n")
      (".hidden" . "h\n") ("odd\nname" . "o\n") ("pkg/go.mod" . "module pkg\n") ("pkg/main.go" . "package main\n")))
  (add-submodule! "src/app" "src/lib" "libs/lib")
  (run! "src/app" "git" "-c" "protocol.file.allow=always" "submodule" "update" "-q" "--init" "--recursive")
  (run! "src/app" "git" "commit" "-qm" "lib")
  (run! "src/app" "git" "worktree" "add" "-q" "--detach" (path "src/app-wt"))
  (write-file! "src/app/notes.txt" "untracked\n")
  (write-file! "src/app/x.log" "ignored\n")
  (write-file! "src/app/build/out" "ignored\n")
  (write-file! "hg-thing/.hg/store" "s\n")
  (write-file! "hg-thing/a.txt" "a\n")
  (write-file! "hg-thing/a.o" "object\n")
  (write-file! "hg-thing/sub/b.txt" "b\n")
  (run! "hg-thing" "ln" "-s" "a.txt" "link-to-file")
  (run! "hg-thing" "ln" "-s" "sub" "link-to-folder")
  (write-file! "notes/n.txt" "n\n")
  (write-file! "notes/proj/.project" "")
  (write-file! "notes/proj/p.txt" "p\n"))

(define (root-of folder)
  (let ([project (projects:find (path folder))])
    (and project (projects:root project))))

;; A listing promises no order.
(define (listed project)
  (let ([paths '()] [done? #f])
    (projects:list-files project
      (lambda (files)
        (if (eof-object? files)
            (set! done? #t)
            (set! paths (append (vector->list files) paths)))))
    (test-runner:wait-until (lambda () done?))
    (list-sort string<? paths)))

(define (listed-in folder) (listed (projects:find (path folder))))
