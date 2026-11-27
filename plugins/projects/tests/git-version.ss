(import (tuna) (test) (timers) (processes) (projects) (trees))

(trees:make!)

;; projects runs the git it finds on the PATH, and asks its version once
;; per load, so a stand-in first on the PATH answers for git.
(define fake-git (trees:path "fake-git"))

(putenv "PATH" (string-append fake-git ":" (getenv "PATH")))

(define (fake-git! version)
  (trees:write-file! "fake-git/git"
    (string-append
      "#!/bin/sh\n"
      "echo \"$*\" >> \"$HOME/fake-git/calls\"\n"
      "PATH=${PATH#*:}\n"
      "case \"$1\" in version) echo '" version "'; exit 0;; esac\n"
      "for a; do [ \"$a\" = --sparse ] && { echo \"error: unknown option \\`sparse'\" >&2; exit 129; }; done\n"
      "exec git \"$@\"\n"))
  (trees:run! "fake-git" "chmod" "+x" "git")
  (forget-calls!))

(define (forget-calls!)
  (let ([file (string-append fake-git "/calls")])
    (when (file-exists? file) (delete-file file))))

(define (calls)
  (let ([file (string-append fake-git "/calls")])
    (if (file-exists? file)
        (call-with-input-file file
          (lambda (p)
            (let loop ([lines '()])
              (let ([line (get-line p)])
                (if (eof-object? line) (list-sort string<? lines) (loop (cons line lines)))))))
        '())))

(test "projects:list-with-git asks git its version once, and passes --deduplicate from git 2.31 and --sparse from 2.35"
  (fake-git! "git version 2.34.1")
  (check-equal? '(".gitignore" ".gitmodules" ".hidden" "README" "lib/a.ss" "lib/deep/b.ss" "libs/lib/.gitmodules" "libs/lib/lib.ss"
                  "libs/lib/vendor/inner/inner.ss" "notes.txt" "odd\nname" "pkg/go.mod" "pkg/main.go")
    (trees:listed-in "src/app/libs/lib"))
  (check-equal? '("ls-files -z -c -o --exclude-standard --deduplicate" "ls-files -z -c -o --exclude-standard --deduplicate"
                  "ls-files -z -c -o --exclude-standard --deduplicate" "version")
    (calls))
  (forget-calls!)
  (check-equal? '(".gitmodules" "lib.ss" "vendor/inner/inner.ss") (trees:listed-in "src/lib"))
  (check-equal? '("ls-files -z -c -o --exclude-standard --deduplicate" "ls-files -z -c -o --exclude-standard --deduplicate")
    (calls)))

(test "a version with words after its numbers is read by its numbers, one older than 2.31 gets neither option, and a reload of projects forgets the version"
  (fake-git! "git version 2.30.1 (Apple Git-130)")
  (reload-modules! '((projects)))
  (check-equal? '(".gitmodules" "lib.ss" "vendor/inner/inner.ss") (trees:listed-in "src/lib"))
  (check-equal? '("ls-files -z -c -o --exclude-standard" "ls-files -z -c -o --exclude-standard" "version") (calls)))

(test "a version it cannot read counts as 0, so neither option is passed"
  (fake-git! "not a version")
  (reload-modules! '((projects)))
  (check-equal? '(".gitmodules" "lib.ss" "vendor/inner/inner.ss") (trees:listed-in "src/lib"))
  (check-equal? '("ls-files -z -c -o --exclude-standard" "ls-files -z -c -o --exclude-standard" "version") (calls)))

(test "when git version cannot start the listing ends with no paths, and processes reports why"
  (reload-modules! '((projects)))
  (let* ([path (getenv "PATH")] [reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (putenv "PATH" (trees:path "no-programs"))
    (advice-add! report keep)
    (let ([listed (trees:listed-in "src/lib")])
      (advice-remove! report keep)
      (putenv "PATH" path)
      (check-equal? '() listed)
      (check-equal? '("cannot run git: No such file or directory") (map condition-message reported)))))

(test "stopping a listing while git's version is asked stops it all"
  (forget-calls!)
  (reload-modules! '((projects)))
  (let ([deliveries 0])
    ((projects:list-files (projects:find (trees:path "src/lib")) (lambda (files) (set! deliveries (+ deliveries 1)))))
    (timers:sleep 0.5)
    (check-equal? 0 deliveries)
    (check-equal? '() (remove "version" (calls)))))
