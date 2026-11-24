(import (tuna) (testing) (tuna plugins) (tuna eval))
(use-plugin projects)

(define home (getenv "HOME"))


(define (sh command)
  (unless (zero? (system (string-append "{ set -e; cd \"$HOME\"; " command "; } < /dev/null")))
    (error 'sh "failed" command)))

(define (write-file! path text)
  (sh (string-append "mkdir -p \"$(dirname '" path "')\""))
  (call-with-output-file (string-append home "/" path) (lambda (p) (display text p)) '(replace)))

(define (root-of folder)
  (let ([project (projects:find (string-append home "/" folder))])
    (and project (projects:root project))))

;; Each delivery's paths, sorted, since a listing promises no order.
(define (listed project)
  (let ([paths '()] [done? #f])
    (projects:list-files project
      (lambda (files)
        (if (eof-object? files)
            (set! done? #t)
            (set! paths (append (vector->list files) paths)))))
    (testing:wait-until (lambda () done?))
    (list-sort string<? paths)))

(define (listed-in folder) (listed (projects:find (string-append home "/" folder))))

(putenv "GIT_AUTHOR_NAME" "Tuna")
(putenv "GIT_AUTHOR_EMAIL" "tuna@example.org")
(putenv "GIT_COMMITTER_NAME" "Tuna")
(putenv "GIT_COMMITTER_EMAIL" "tuna@example.org")

(define (repository! folder files)
  (for-each (lambda (file) (write-file! (string-append folder "/" (car file)) (cdr file))) files)
  (sh (string-append "cd " folder " && git init -q -b main && git add -A && git commit -qm one")))

(repository! "src/inner" '(("inner.ss" . "i\n")))
(repository! "src/lib" '(("lib.ss" . "l\n")))
(sh "cd src/lib && git -c protocol.file.allow=always submodule add -q \"$HOME/src/inner\" vendor/inner && git commit -qm inner")
(repository! "src/app"
  '(("README" . "r\n") ("lib/a.ss" . "a\n") ("lib/deep/b.ss" . "b\n") (".gitignore" . "*.log\nbuild/\n")
    (".hidden" . "h\n") ("odd\nname" . "o\n") ("pkg/go.mod" . "module pkg\n") ("pkg/main.go" . "package main\n")))
(sh (string-append "cd src/app && git -c protocol.file.allow=always submodule add -q \"$HOME/src/lib\" libs/lib"
                   " && git -c protocol.file.allow=always submodule update -q --init --recursive && git commit -qm lib"
                   " && git worktree add -q --detach \"$HOME/src/app-wt\""))
(write-file! "src/app/notes.txt" "untracked\n")
(write-file! "src/app/x.log" "ignored\n")
(write-file! "src/app/build/out" "ignored\n")
(write-file! "hg-thing/.hg/store" "s\n")
(write-file! "hg-thing/a.txt" "a\n")
(write-file! "hg-thing/a.o" "object\n")
(write-file! "hg-thing/sub/b.txt" "b\n")
(sh "cd hg-thing && ln -s a.txt link-to-file && ln -s sub link-to-folder")
(write-file! "notes/n.txt" "n\n")
(write-file! "notes/proj/.project" "")
(write-file! "notes/proj/p.txt" "p\n")
(import (console))
