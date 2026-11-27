(import (tuna) (test) (hooks) (options) (projects) (projects-test trees))

(define (violation thunk)
  (guard (c [(assertion-violation? c) (list (condition-who c) (condition-message c))])
    (thunk)
    'no-violation))

(projects-test/trees:make!)

(test "projects:find gives the project of the nearest folder holding .git, .svn, .bzr or .hg, its root ending in /"
  (check-equal? (map projects-test/trees:path '("src/app/" "src/app/" "src/app/" "hg-thing/"))
    (map projects-test/trees:root-of '("src/app" "src/app/lib/deep" "src/app/lib/deep/" "hg-thing/sub")))
  (check-equal? #f (projects-test/trees:root-of "notes/proj")))

(test "a git submodule belongs to the project of the repository holding it, through any depth; a worktree is a project of its own"
  (check-equal? (map projects-test/trees:path '("src/app/" "src/app/" "src/app-wt/"))
    (map projects-test/trees:root-of '("src/app/libs/lib" "src/app/libs/lib/vendor/inner" "src/app-wt/lib"))))

(test "a submodule of a worktree belongs to the worktree's project"
  (projects-test/trees:run! "src/app-wt" "git" "-c" "protocol.file.allow=always" "submodule" "update" "-q" "--init")
  (check-equal? (projects-test/trees:path "src/app-wt/") (projects-test/trees:root-of "src/app-wt/libs/lib")))

(test "with projects:merge-submodules? off, a submodule is a project of its own"
  (options:with ([projects:merge-submodules? #f])
    (check-equal? (map projects-test/trees:path '("src/app/libs/lib/" "src/app/libs/lib/vendor/inner/"))
      (map projects-test/trees:root-of '("src/app/libs/lib" "src/app/libs/lib/vendor/inner")))))

(test "an extra root marker makes its folder a root, inside a repository or outside any"
  (options:with ([projects:extra-root-markers (list "go.mod" ".project")])
    (check-equal? (map projects-test/trees:path '("src/app/pkg/" "src/app/" "notes/proj/"))
      (map projects-test/trees:root-of '("src/app/pkg" "src/app/lib" "notes/proj")))))

(test "a finder added at the default depth is asked before projects:try-vc"
  (let ([notes-finder (lambda (folder)
                        (and (string=? folder (projects-test/trees:path "notes/"))
                             (projects:make-project folder projects:list-with-find)))])
    (hooks:add! projects:finders notes-finder)
    (let ([roots (map projects-test/trees:root-of '("notes" "src/app"))] [found (projects:find (projects-test/trees:path "notes"))])
      (hooks:remove! projects:finders notes-finder)
      (check-equal? (map projects-test/trees:path '("notes/" "src/app/")) roots)
      (check (projects:project? found))))
  (check-equal? #f (projects-test/trees:root-of "notes")))

(test "a finder that raises ends the search with its condition"
  (let ([failing (lambda (folder) (error 'failing-finder "no answer"))])
    (hooks:add! projects:finders failing)
    (let ([raised (guard (c [(error? c) (condition-who c)]) (projects:find (projects-test/trees:path "src/app")))])
      (hooks:remove! projects:finders failing)
      (check-equal? 'failing-finder raised))))

(test "what code passes is checked"
  (let ([yes (lambda (folder) 'yes)])
    (hooks:add! projects:finders yes)
    (check-equal? '(projects:find "a finder answered neither a project nor #f")
      (violation (lambda () (projects:find (projects-test/trees:path "src")))))
    (hooks:remove! projects:finders yes))
  (check-equal? '(projects:find "not an absolute path") (violation (lambda () (projects:find "src/app"))))
  (check-equal? '(projects:try-vc "not an absolute path") (violation (lambda () (projects:try-vc 'app))))
  (check-equal? '(projects:make-project "not an absolute path")
    (violation (lambda () (projects:make-project "~/app" projects:list-with-git))))
  (check-equal? '(projects:make-project "not a procedure") (violation (lambda () (projects:make-project (projects-test/trees:path "") 'git))))
  (check-equal? '(projects:root "not a project") (violation (lambda () (projects:root 'app))))
  (check (not (projects:project? 'app)))
  (check-raises assertion-violation? (options:set! projects:extra-root-markers (list "a/b"))))
