(import (tuna) (test) (test-runner) (timers) (options) (projects) (projects-test trees))

(define (violation thunk)
  (guard (c [(assertion-violation? c) (list (condition-who c) (condition-message c))])
    (thunk)
    'no-violation))

(projects-test/trees:make!)

(define app-files
  '(".gitignore" ".gitmodules" ".hidden" "README" "lib/a.ss" "lib/deep/b.ss" "notes.txt" "odd\nname" "pkg/go.mod" "pkg/main.go"))

(test "a git project lists as git ls-files does, each path relative to the root, then each submodule's files under its path"
  (check-equal? (list-sort string<? (append app-files '("libs/lib/.gitmodules" "libs/lib/lib.ss" "libs/lib/vendor/inner/inner.ss")))
    (projects-test/trees:listed-in "src/app/lib")))

(test "an untracked repository inside a project, which git lists as a folder, is left out"
  (projects-test/trees:write-file! "src/app/nested/n.txt" "n\n")
  (projects-test/trees:run! "src/app/nested" "git" "init" "-q")
  (check (not (exists (lambda (path) (and (>= (string-length path) 6) (string=? "nested" (substring path 0 6)))) (projects-test/trees:listed-in "src/app"))))
  (projects-test/trees:run! "src/app" "rm" "-rf" "nested"))

(test "with projects:merge-submodules? off, a project's listing leaves its submodules' files out"
  (options:set! projects:merge-submodules? #f)
  (let ([app (projects-test/trees:listed-in "src/app")] [lib (projects-test/trees:listed-in "src/app/libs/lib")])
    (options:unset! projects:merge-submodules?)
    (check-equal? app-files app)
    (check-equal? '(".gitmodules" "lib.ss") lib)))

(test "a root found by an extra marker inside a repository lists its own files with git, a submodule under it in its place"
  (options:set! projects:extra-root-markers (list "go.mod" ".project"))
  (projects-test/trees:write-file! "src/app/libs/go.mod" "module libs\n")
  (let ([pkg (projects-test/trees:listed-in "src/app/pkg")] [libs (projects-test/trees:listed-in "src/app/libs")])
    (options:unset! projects:extra-root-markers)
    (check-equal? '("go.mod" "main.go") pkg)
    (check-equal? '("go.mod" "lib/.gitmodules" "lib/lib.ss" "lib/vendor/inner/inner.ss") libs)))

(test "elsewhere find lists the regular files and links to them, follows no link to a folder, and leaves out projects:ignores"
  (check-equal? '("a.txt" "link-to-file" "sub/b.txt") (projects-test/trees:listed-in "hg-thing"))
  (options:set! projects:extra-root-markers (list ".project"))
  (check-equal? '(".project" "p.txt") (projects-test/trees:listed-in "notes/proj"))
  (options:set! projects:ignores (list "./sub/" "*.txt"))
  (let ([listed (projects-test/trees:listed-in "hg-thing")])
    (options:unset! projects:ignores)
    (options:unset! projects:extra-root-markers)
    (check-equal? '(".hg/store" "a.o" "link-to-file") listed)))

(test "a program's complaint is reported as a warning, and the paths it listed stay"
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (let ([listed (projects-test/trees:listed (projects:make-project (projects-test/trees:path "notes") projects:list-with-git))])
      (advice-remove! report keep)
      (check-equal? '() listed)
      (check-equal? 1 (length reported))
      (check (warning? (car reported)))
      (check-equal? 'projects:list-files (condition-who (car reported)))
      (check-equal? "fatal: not a git repository (or any of the parent directories): .git" (condition-message (car reported))))))

(test "the procedure a listing returns stops it: nothing more comes, and calling it again does nothing"
  (let* ([calls 0] [stop (projects:list-files (projects:find (projects-test/trees:path "src/app")) (lambda (files) (set! calls (+ calls 1))))])
    (stop)
    (stop)
    (timers:sleep 0.5)
    (check-equal? 0 calls)))

(test "what code passes is checked"
  (check-equal? '(projects:list-files "not a project") (violation (lambda () (projects:list-files 'app values))))
  (check-equal? '(projects:list-files "not a procedure")
    (violation (lambda () (projects:list-files (projects:find (projects-test/trees:path "src/app")) 'show))))
  (check-equal? '(projects:list-files "a lister returned what is not a procedure")
    (violation (lambda () (projects:list-files (projects:make-project (projects-test/trees:path "") (lambda (root on-files) 'stop)) values))))
  (check-equal? '(projects:list-with-git "not an absolute path") (violation (lambda () (projects:list-with-git "app" values))))
  (check-equal? '(projects:list-with-find "not a procedure") (violation (lambda () (projects:list-with-find (projects-test/trees:path "") 'show)))))
